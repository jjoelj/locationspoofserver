#include "LSSQRGen.h"
#include <string.h>

// ---- Galois field GF(256), prim 0x11d ----
static uint8_t gf_exp[512];
static uint8_t gf_log[256];
static void gf_init(void) {
    int x = 1;
    for (int i = 0; i < 255; i++) { gf_exp[i] = (uint8_t)x; gf_log[x] = (uint8_t)i; x <<= 1; if (x & 0x100) x ^= 0x11d; }
    for (int i = 255; i < 512; i++) gf_exp[i] = gf_exp[i - 255];
}
static uint8_t gf_mul(uint8_t a, uint8_t b) {
    if (!a || !b) return 0;
    return gf_exp[gf_log[a] + gf_log[b]];
}

// Reed-Solomon (ported from Nayuki qrcodegen, known-correct).
static void rs_divisor(int degree, uint8_t *result) {
    memset(result, 0, (size_t)degree);
    result[degree - 1] = 1;
    uint8_t root = 1;
    for (int i = 0; i < degree; i++) {
        for (int j = 0; j < degree; j++) {
            result[j] = gf_mul(result[j], root);
            if (j + 1 < degree) result[j] ^= result[j + 1];
        }
        root = gf_mul(root, 2);
    }
}
static void rs_remainder(const uint8_t *data, int dataLen, const uint8_t *divisor, int degree, uint8_t *result) {
    memset(result, 0, (size_t)degree);
    for (int i = 0; i < dataLen; i++) {
        uint8_t factor = data[i] ^ result[0];
        memmove(result, result + 1, (size_t)(degree - 1));
        result[degree - 1] = 0;
        for (int j = 0; j < degree; j++) result[j] ^= gf_mul(divisor[j], factor);
    }
}

// ---- ECC level L, versions 1-5: {data codewords, ecc codewords} ----
// L rather than M: the payload is a URL plus token (~70 bytes) and M tops out
// at 62 before needing multi-block interleaving. Fine for a code on a screen.
static const int DATA_CW[6] = {0, 19, 34, 55, 80, 108};
static const int ECC_CW[6]  = {0,  7, 10, 15, 20,  26};

// N x N working buffers (max v5 = 37).
#define MAXN 37
static uint8_t g_fn[MAXN * MAXN]; // 1 = function/reserved module (not maskable)

static void set_module(uint8_t *m, int N, int r, int c, int v, int isFn) {
    if (r < 0 || c < 0 || r >= N || c >= N) return;
    m[r * N + c] = (uint8_t)(v & 1);
    if (isFn) g_fn[r * N + c] = 1;
}

static void draw_finder(uint8_t *m, int N, int r, int c) {
    for (int dr = -1; dr <= 7; dr++)
        for (int dc = -1; dc <= 7; dc++) {
            int rr = r + dr, cc = c + dc;
            if (rr < 0 || cc < 0 || rr >= N || cc >= N) continue;
            int dist = (dr < 0 || dr > 6 || dc < 0 || dc > 6) ? 8 :
                       ((dr == 0 || dr == 6 || dc == 0 || dc == 6) ? 0 :
                        ((dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4) ? 0 : 1));
            set_module(m, N, rr, cc, dist == 0 ? 1 : 0, 1);
        }
}

static void draw_alignment(uint8_t *m, int N, int cr, int cc) {
    for (int dr = -2; dr <= 2; dr++)
        for (int dc = -2; dc <= 2; dc++) {
            int ring = (dr == 0 && dc == 0) ? 1 : ((dr <= -2 || dr >= 2 || dc <= -2 || dc >= 2) ? 1 : 0);
            set_module(m, N, cr + dr, cc + dc, ring, 1);
        }
}

// Reserve format-info modules (values written later).
static void reserve_format(uint8_t *m, int N) {
    for (int i = 0; i <= 5; i++) { set_module(m, N, 8, i, 0, 1); set_module(m, N, i, 8, 0, 1); }
    set_module(m, N, 8, 7, 0, 1); set_module(m, N, 8, 8, 0, 1); set_module(m, N, 7, 8, 0, 1);
    for (int i = 0; i < 8; i++) { set_module(m, N, 8, N - 1 - i, 0, 1); set_module(m, N, N - 1 - i, 8, 0, 1); }
    set_module(m, N, N - 8, 8, 1, 1); // dark module
}

static void draw_function_patterns(uint8_t *m, int N, int version) {
    // timing
    for (int i = 8; i < N - 8; i++) {
        set_module(m, N, 6, i, (i % 2 == 0) ? 1 : 0, 1);
        set_module(m, N, i, 6, (i % 2 == 0) ? 1 : 0, 1);
    }
    draw_finder(m, N, 0, 0);
    draw_finder(m, N, 0, N - 7);
    draw_finder(m, N, N - 7, 0);
    // v2-6 have exactly one alignment pattern, at (N-7, N-7); the other three
    // candidate centers collide with the finders and are omitted.
    if (version >= 2) draw_alignment(m, N, N - 7, N - 7);
    reserve_format(m, N);
}

static int mask_bit(int mask, int r, int c) {
    switch (mask) {
        case 0: return (r + c) % 2 == 0;
        case 1: return r % 2 == 0;
        case 2: return c % 3 == 0;
        case 3: return (r + c) % 3 == 0;
        case 4: return (r / 2 + c / 3) % 2 == 0;
        case 5: return (r * c) % 2 + (r * c) % 3 == 0;
        case 6: return ((r * c) % 2 + (r * c) % 3) % 2 == 0;
        case 7: return ((r + c) % 2 + (r * c) % 3) % 2 == 0;
    }
    return 0;
}

// Place data bitstream in zigzag, skipping function modules.
static void place_data(uint8_t *m, int N, const uint8_t *bits, int nbits) {
    int idx = 0;
    for (int col = N - 1; col >= 1; col -= 2) {
        if (col == 6) col = 5; // skip timing column
        for (int t = 0; t < N; t++) {
            int upward = ((col + 1) & 2) == 0; // alternate direction per column pair
            int row = upward ? (N - 1 - t) : t;
            for (int k = 0; k < 2; k++) {
                int cc = col - k;
                if (g_fn[row * N + cc]) continue;
                int bit = (idx < nbits) ? bits[idx] : 0;
                m[row * N + cc] = (uint8_t)bit;
                idx++;
            }
        }
    }
}

static void apply_mask(uint8_t *m, int N, int mask) {
    for (int r = 0; r < N; r++)
        for (int c = 0; c < N; c++)
            if (!g_fn[r * N + c] && mask_bit(mask, r, c))
                m[r * N + c] ^= 1;
}

// ---- penalty scoring (spec rules 1-4) ----
static int penalty(const uint8_t *m, int N) {
    int p = 0;
    // rule 1: runs of >=5 in rows and cols
    for (int r = 0; r < N; r++) {
        int run = 1;
        for (int c = 1; c < N; c++) {
            if (m[r * N + c] == m[r * N + c - 1]) { run++; if (run == 5) p += 3; else if (run > 5) p++; }
            else run = 1;
        }
    }
    for (int c = 0; c < N; c++) {
        int run = 1;
        for (int r = 1; r < N; r++) {
            if (m[r * N + c] == m[(r - 1) * N + c]) { run++; if (run == 5) p += 3; else if (run > 5) p++; }
            else run = 1;
        }
    }
    // rule 2: 2x2 blocks
    for (int r = 0; r < N - 1; r++)
        for (int c = 0; c < N - 1; c++) {
            uint8_t v = m[r * N + c];
            if (v == m[r * N + c + 1] && v == m[(r + 1) * N + c] && v == m[(r + 1) * N + c + 1]) p += 3;
        }
    // rule 3: finder-like pattern 1011101 with 4-white padding, rows and cols
    static const int pat[7] = {1, 0, 1, 1, 1, 0, 1};
    for (int r = 0; r < N; r++)
        for (int c = 0; c <= N - 7; c++) {
            int ok = 1; for (int k = 0; k < 7; k++) if (m[r * N + c + k] != pat[k]) { ok = 0; break; }
            if (ok) {
                int before = 1; for (int k = c - 4; k < c; k++) { if (k < 0 || m[r * N + k] != 0) { before = 0; break; } }
                int after = 1;  for (int k = c + 7; k < c + 11; k++) { if (k >= N || m[r * N + k] != 0) { after = 0; break; } }
                if (before || after) p += 40;
            }
        }
    for (int c = 0; c < N; c++)
        for (int r = 0; r <= N - 7; r++) {
            int ok = 1; for (int k = 0; k < 7; k++) if (m[(r + k) * N + c] != pat[k]) { ok = 0; break; }
            if (ok) {
                int before = 1; for (int k = r - 4; k < r; k++) { if (k < 0 || m[k * N + c] != 0) { before = 0; break; } }
                int after = 1;  for (int k = r + 7; k < r + 11; k++) { if (k >= N || m[k * N + c] != 0) { after = 0; break; } }
                if (before || after) p += 40;
            }
        }
    // rule 4: proportion of dark
    int dark = 0; for (int i = 0; i < N * N; i++) dark += m[i];
    int percent = dark * 100 / (N * N);
    int k = 0; int lo = percent - percent % 5, hi = lo + 5;
    int a = (lo >= 50 ? lo - 50 : 50 - lo) / 5, b = (hi >= 50 ? hi - 50 : 50 - hi) / 5;
    k = a < b ? a : b;
    p += k * 10;
    return p;
}

static void set_format(uint8_t *m, int N, int mask) {
    int data = (1 << 3) | mask; // ECC level L = 0b01
    int rem = data;
    for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    int bits = ((data << 10) | rem) ^ 0x5412;
    // Top-left copy: bits 0-8 run down column 8, bits 9-14 left along row 8.
    // Easy to transpose by mistake, and scanners that fall back to the second
    // copy below will hide it from you.
    for (int i = 0; i <= 5; i++) set_module(m, N, i, 8, (bits >> i) & 1, 1);
    set_module(m, N, 7, 8, (bits >> 6) & 1, 1);
    set_module(m, N, 8, 8, (bits >> 7) & 1, 1);
    set_module(m, N, 8, 7, (bits >> 8) & 1, 1);
    for (int i = 9; i < 15; i++) set_module(m, N, 8, 14 - i, (bits >> i) & 1, 1);
    // top-right + bottom-left
    for (int i = 0; i < 8; i++) set_module(m, N, 8, N - 1 - i, (bits >> i) & 1, 1);
    for (int i = 8; i < 15; i++) set_module(m, N, N - 15 + i, 8, (bits >> i) & 1, 1);
    set_module(m, N, N - 8, 8, 1, 1); // dark module stays
}

int lss_qr_encode(const uint8_t *data, int len, uint8_t *modules) {
    gf_init();

    // pick smallest version 1-5 that fits (byte mode: 4 + 8 + 8*len + 4 <= dataCW*8)
    int version = 0;
    for (int v = 1; v <= 5; v++) {
        int cap = DATA_CW[v] * 8;
        if (4 + 8 + 8 * len + 4 <= cap) { version = v; break; }
    }
    if (version == 0) return 0;

    int N = 17 + 4 * version;
    int dataCW = DATA_CW[version], eccCW = ECC_CW[version];

    // build data codewords
    uint8_t cw[108]; memset(cw, 0, sizeof(cw));
    // bit-pack: mode(0100), count(8), bytes(8 each), terminator
    int bitpos = 0;
    #define PUT(val, n) do { for (int _i = n - 1; _i >= 0; _i--) { if ((val >> _i) & 1) cw[bitpos >> 3] |= (uint8_t)(0x80 >> (bitpos & 7)); bitpos++; } } while (0)
    PUT(0x4, 4);
    PUT(len, 8);
    for (int i = 0; i < len; i++) PUT(data[i], 8);
    PUT(0x0, 4); // terminator (fits: we chose a version with room)
    // pad to byte boundary already handled by bit packing; fill remaining codewords
    int usedCW = (bitpos + 7) / 8;
    for (int i = usedCW; i < dataCW; i++) cw[i] = (i - usedCW) % 2 == 0 ? 0xEC : 0x11;

    // ecc
    uint8_t divisor[26], ecc[26];
    rs_divisor(eccCW, divisor);
    rs_remainder(cw, dataCW, divisor, eccCW, ecc);

    // full bitstream = data codewords ++ ecc codewords (single block)
    uint8_t bits[(108 + 26) * 8]; int nbits = 0;
    for (int i = 0; i < dataCW; i++) for (int b = 7; b >= 0; b--) bits[nbits++] = (cw[i] >> b) & 1;
    for (int i = 0; i < eccCW; i++) for (int b = 7; b >= 0; b--) bits[nbits++] = (ecc[i] >> b) & 1;

    // draw
    memset(modules, 0, (size_t)(N * N));
    memset(g_fn, 0, sizeof(g_fn));
    draw_function_patterns(modules, N, version);
    place_data(modules, N, bits, nbits);

    // choose best mask by penalty scoring
    int bestMask = 0, bestPen = 0x7fffffff;
    uint8_t trial[MAXN * MAXN];
    for (int mask = 0; mask < 8; mask++) {
        memcpy(trial, modules, (size_t)(N * N));
        apply_mask(trial, N, mask);
        set_format(trial, N, mask);
        int pen = penalty(trial, N);
        if (pen < bestPen) { bestPen = pen; bestMask = mask; }
    }
    apply_mask(modules, N, bestMask);
    set_format(modules, N, bestMask);
    return N;
}

#ifdef QR_TEST
// Self-check: build with -DQR_TEST, prints "N\n" then the matrix as 0/1 rows.
// Output was verified module-for-module against the `qrcode` Python package
// across version boundaries and UTF-8; 107+ returns 0 (too long).
#include <stdio.h>
int main(int argc, char **argv) {
    const char *s = argc > 1 ? argv[1] : "0123456789abcdef0123456789abcdef";
    uint8_t m[MAXN * MAXN];
    int N = lss_qr_encode((const uint8_t *)s, (int)strlen(s), m);
    if (!N) { fprintf(stderr, "too long\n"); return 1; }
    printf("%d\n", N);
    for (int r = 0; r < N; r++) { for (int c = 0; c < N; c++) putchar(m[r * N + c] ? '1' : '0'); putchar('\n'); }
    return 0;
}
#endif
