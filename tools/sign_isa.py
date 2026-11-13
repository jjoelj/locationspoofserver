#!/usr/bin/env python3
"""Sign Obj-C isa binds in the arm64e slice of a Mach-O, in place.

iOS 18's objc_msgSend authenticates the isa of constant NSStrings and global
blocks (DA key, address-diversified, discriminator 0x6AE1). Apple clang signs
them; LLVM 19 emits plain binds, so the first message to an @"..." crashes.
This rewrites those binds as authenticated ones. Run before codesigning.
"""
import struct, sys

ISA_SYMBOLS = {b"___CFConstantStringClassReference", b"__NSConcreteGlobalBlock"}
CPU_ARM64, SUB_ARM64E = 0x0100000C, 2
LC_SEGMENT_64, LC_DYLD_CHAINED_FIXUPS = 0x19, 0x80000034
PTR_ARM64E = 1


def patch_slice(d, base):
    ncmds = struct.unpack_from("<I", d, base + 16)[0]
    off, segs, fixups = base + 32, [], None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == LC_SEGMENT_64:
            segs.append(struct.unpack_from("<Q", d, off + 40)[0])  # fileoff
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            fixups = base + struct.unpack_from("<I", d, off + 8)[0]
        off += size
    if fixups is None:
        return 0
    _, starts, imports, symbols, count, fmt, _ = struct.unpack_from("<7I", d, fixups)
    width = {1: 4, 2: 8, 3: 16}[fmt]
    isa = set()
    for i in range(count):
        name_off = struct.unpack_from("<I", d, fixups + imports + i * width)[0] >> 9
        name = bytes(d[fixups + symbols + name_off:].split(b"\0", 1)[0])
        if name in ISA_SYMBOLS:
            isa.add(i)

    patched = 0
    s = fixups + starts
    for seg_i in range(struct.unpack_from("<I", d, s)[0]):
        seg_off = struct.unpack_from("<I", d, s + 4 + 4 * seg_i)[0]
        if not seg_off:
            continue
        ss = s + seg_off
        page_size, ptr_fmt, seg_file = struct.unpack_from("<HHQ", d, ss + 4)
        if ptr_fmt != PTR_ARM64E:
            sys.exit(f"sign_isa: unsupported pointer format {ptr_fmt}")
        page_count = struct.unpack_from("<H", d, ss + 20)[0]
        for p in range(page_count):
            start = struct.unpack_from("<H", d, ss + 22 + 2 * p)[0]
            if start == 0xFFFF:  # no fixups on this page
                continue
            at = base + seg_file + p * page_size + start
            while True:
                v = struct.unpack_from("<Q", d, at)[0]
                auth, bind, nxt = v >> 63, (v >> 62) & 1, (v >> 51) & 0x7FF
                ordinal = v & 0xFFFF
                if bind and not auth and ordinal in isa and not (v >> 32) & 0x7FFFF:
                    # auth bind: auth|bind|next|key=DA(2)|addrDiv|diversity|ordinal
                    v = (3 << 62) | (nxt << 51) | (2 << 49) | (1 << 48) | (0x6AE1 << 32) | ordinal
                    struct.pack_into("<Q", d, at, v)
                    patched += 1
                if not nxt:
                    break
                at += nxt * 8
    return patched


def main(path):
    d = bytearray(open(path, "rb").read())
    magic = struct.unpack_from(">I", d, 0)[0]
    slices = []
    if magic == 0xCAFEBABE:
        for i in range(struct.unpack_from(">I", d, 4)[0]):
            cpu, sub, off = struct.unpack_from(">III", d, 8 + 20 * i)
            if cpu == CPU_ARM64 and sub & 0xFF == SUB_ARM64E:
                slices.append(off)
    else:
        cpu, sub = struct.unpack_from("<II", d, 4)
        if cpu == CPU_ARM64 and sub & 0xFF == SUB_ARM64E:
            slices.append(0)
    n = sum(patch_slice(d, off) for off in slices)
    open(path, "wb").write(d)
    print(f"sign_isa: signed {n} isa pointers in {path}")


if __name__ == "__main__":
    main(sys.argv[1])
