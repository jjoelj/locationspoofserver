ARCHS = arm64

TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = LocationSpoofServer

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = LocationSpoofServer

LocationSpoofServer_FILES = app/LSSAppDelegate.m \
							app/LSSRootViewController.m \
							app/LSSDaemonClient.m \
							app/LSSLogger.m \
							app/LSSQRGen.c \
							app/main.m

LocationSpoofServer_FRAMEWORKS = UIKit CoreGraphics Foundation
LocationSpoofServer_CFLAGS = -fobjc-arc -Iapp
LocationSpoofServer_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

TOOL_NAME = locationspoofd fmfwatchd tsboot
locationspoofd_INSTALL_PATH = /usr/libexec/

locationspoofd_FILES = daemon/LSSLocalHTTPServer.m \
					   daemon/LSSControlHTTPServer.m \
					   daemon/LSSLocSimController.m \
					   daemon/LSSLogger.m \
					   daemon/LSSDaemonController.m \
					   daemon/main.m

locationspoofd_FRAMEWORKS = Foundation CoreLocation IOKit
locationspoofd_CFLAGS = -fobjc-arc -Idaemon
locationspoofd_CODESIGN_FLAGS = -Sentitlements.plist

# FMF friend-location watcher. Separate binary with fmfd.access but NOT
# platform-application (that combo is AMFI-killed on device). Runs as its own
# LaunchDaemon; locationspoofd talks to it over localhost.
fmfwatchd_INSTALL_PATH = /usr/libexec/
fmfwatchd_FILES = daemon/fmf_watch_main.m
fmfwatchd_FRAMEWORKS = Foundation CoreLocation
fmfwatchd_CFLAGS = -fobjc-arc
fmfwatchd_CODESIGN_FLAGS = -Sentitlements_fmf.plist

# launchd cannot spawn tailscaled itself; see daemon/tsboot_main.c.
tsboot_INSTALL_PATH = /usr/libexec/
tsboot_FILES = daemon/tsboot_main.c
tsboot_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk

# One-function backfill so the Go-built Tailscale binaries load on iOS 14.
# Re-exports Security so every other symbol still resolves through it.
LIBRARY_NAME = securityshim
securityshim_FILES = tools/securityshim.m
securityshim_INSTALL_PATH = /usr/lib
securityshim_FRAMEWORKS = CoreFoundation
securityshim_CFLAGS = -fobjc-arc
# Security is linked only via -reexport_framework; listing it in FRAMEWORKS too
# would add a plain LC_LOAD_DYLIB and the re-export would not happen.
securityshim_LDFLAGS = -Wl,-reexport_framework,Security

include $(THEOS_MAKE_PATH)/library.mk

# Tailscale, so the phone can expose itself over Funnel without an SSH-forward
# relay box. Built from source on demand and dropped into the package; the 58MB
# of binaries stay out of git. Needs `go` on PATH. See README.
TAILSCALE_VERSION = v1.102.4
TS_BIN = layout/usr/local/bin
# Not /var/run/tailscaled.socket: that one belongs to the Tailscale iOS app.
TS_SOCK = /var/run/lss-tailscaled.socket
TS_CLI = /usr/local/bin/tailscale --socket=$(TS_SOCK)
LDID ?= $(THEOS)/toolchain/linux/iphone/bin/ldid

# before-stage, not before-package: staging copies layout/ into the package
# tree, and it runs first. Built here, the binaries would land in layout/ after
# the copy and ship in the *next* build instead of this one.
before-stage:: $(TS_BIN)/tailscaled $(TS_BIN)/tailscale

$(TS_BIN)/%:
	@command -v go >/dev/null || { echo "error: go not on PATH, needed to build $*"; exit 1; }
	# -w is load-bearing, not just size: iOS's dyld rejects Go's __DWARF segment
	# ("filesize is larger than vmsize") and the binary won't exec at all.
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go install -ldflags="-s -w" tailscale.com/cmd/$*@$(TAILSCALE_VERSION)
	@mkdir -p $(TS_BIN)
	cp "$$(go env GOPATH)/bin/darwin_arm64/$*" $@
	python3 tools/ios_platform.py $@
	$(LDID) -S $@

# Daemon loading lives in layout/DEBIAN/postinst, so a Sileo install gets it
# too; dpkg runs that for `make install` as well. Nothing to repeat here.
after-install::
	@echo ""
	@echo "  Not logged into Tailscale yet: open LocationSpoofServer on the"
	@echo "  phone and tap 'Log in to Tailscale'."
	@echo ""
