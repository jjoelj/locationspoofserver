// Backfills SecTrustCopyCertificateChain for iOS 14.
//
// Go's crypto/x509 calls it unconditionally on darwin, but Apple shipped it in
// iOS 15. Everything else Go imports from Security exists on 14.x, so this
// dylib re-exports Security and adds the one missing function; the Tailscale
// binaries get their Security load command pointed here (tools/ios_platform.py).
//
// Semantics match Apple's: a +1 CFArrayRef of the chain, or NULL if there is
// none, built from the index-based API that goes back to iOS 2.

#import <Security/Security.h>
#import <CoreFoundation/CoreFoundation.h>

CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust) {
    if (trust == NULL) return NULL;

    CFIndex count = SecTrustGetCertificateCount(trust);
    if (count <= 0) return NULL;

    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    if (chain == NULL) return NULL;

    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
        if (cert == NULL) { CFRelease(chain); return NULL; }
        CFArrayAppendValue(chain, cert); // CFArray retains
    }
    return chain;
}
