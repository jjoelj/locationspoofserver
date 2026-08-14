#ifndef LSS_QRGEN_H
#define LSS_QRGEN_H
#include <stdint.h>

// Minimal QR encoder: byte mode, ECC level L, auto version 1-5 (single block).
// Caps at 106 bytes (v5-L). Payload is a URL plus a 32-hex token, so ~70;
// longer custom tokens return 0 and the UI falls back to the text label.
// Going past v5 needs multi-block interleaving, which this does not do.
// Writes an N*N matrix of 0/1 into `modules` (needs >= 37*37 bytes).
// Returns N (side length) on success, 0 if data too long.
int lss_qr_encode(const uint8_t *data, int len, uint8_t *modules);

#endif
