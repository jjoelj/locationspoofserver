#!/usr/bin/env python3
"""Retarget a darwin/arm64 Mach-O from macOS to iOS, in place.

Go can only cross-compile GOOS=darwin without cgo, which produces a macOS
binary in two ways iOS rejects:

  1. LC_BUILD_VERSION says platform=1 (macOS), so dyld refuses the image
     outright: "mach-o, but not built for platform macOS".
  2. Framework loads use the macOS bundle layout, .../Foo.framework/Versions/A/Foo.
     iOS frameworks are flat, .../Foo.framework/Foo, so the load fails.

Both are metadata; the arm64 code itself is fine, and the dylibs it wants
(libSystem, libresolv, CoreFoundation, Security) all exist on iOS. The
rewritten paths are strictly shorter, so they fit in place with NUL padding
and no load command needs resizing.

Run before codesigning; ldid's signature covers these bytes.
"""
import struct, sys

PLATFORM_IOS, MIN_IOS = 2, 14 << 16  # matches TARGET's 14.0 floor in the Makefile
LC_BUILD_VERSION = 0x32
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB = 0xC, 0x80000018
MACOS_FRAMEWORK_INFIX = "/Versions/A/"

# Go calls SecTrustCopyCertificateChain, which is iOS 15+. Point Security at
# our shim, which defines it and re-exports the real framework. Harmless on
# iOS 15+: the shim's implementation is equivalent to Apple's.
SECURITY_PATH = "/System/Library/Frameworks/Security.framework/Security"
SECURITY_SHIM = "/usr/lib/securityshim.dylib"  # theos does not add a lib prefix

def patch(path):
    with open(path, "r+b") as f:
        buf = bytearray(f.read())
        magic, = struct.unpack_from("<I", buf, 0)
        if magic != 0xFEEDFACF:
            sys.exit(f"{path}: not a 64-bit little-endian Mach-O ({magic:#x})")
        ncmds, = struct.unpack_from("<I", buf, 16)

        off, patched, relinked = 32, 0, []
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", buf, off)
            if cmd == LC_BUILD_VERSION:
                struct.pack_into("<III", buf, off + 8, PLATFORM_IOS, MIN_IOS, MIN_IOS)
                patched += 1
            elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
                stroff, = struct.unpack_from("<I", buf, off + 8)
                start, end = off + stroff, off + cmdsize
                old = buf[start:end].split(b"\x00")[0].decode()
                new = old.replace(MACOS_FRAMEWORK_INFIX, "/")
                if new == SECURITY_PATH:
                    new = SECURITY_SHIM
                if new != old:
                    if len(new) >= end - start:
                        sys.exit(f"{path}: {new!r} does not fit in {end - start} bytes")
                    buf[start:end] = new.encode().ljust(end - start, b"\x00")
                    relinked.append(new)
            off += cmdsize

        if patched != 1:
            sys.exit(f"{path}: expected 1 LC_BUILD_VERSION, found {patched}")
        f.seek(0)
        f.write(buf)
    print(f"{path}: retargeted to iOS {MIN_IOS >> 16}.0"
          + (f", relinked {len(relinked)} framework(s)" if relinked else ""))

if __name__ == "__main__":
    for p in sys.argv[1:]:
        patch(p)
