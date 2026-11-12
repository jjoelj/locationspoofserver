ARCHS = arm64 arm64e
# LLVM 19 (L1ghtmann v19.0.0-L2): the LSSFindMy tweak loads into Messages, an
# arm64e process, and iOS 14+ only loads new-ABI arm64e. Theos's default
# clang 13 emits the old ABI.
SDKBINPATH = $(THEOS)/toolchain/iphone-llvm19/linux/iphone/bin

TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = LocationSpoofServer
# The install prefix is compiled in, so each scheme needs its own objects.
THEOS_OBJ_DIR_NAME = obj/$(or $(THEOS_PACKAGE_SCHEME),rootful)$(_THEOS_OBJ_DIR_EXTENSION)

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

# Reads friends' locations through Messages' own Find My client and hands them
# to fmfwatchd. See tweak/LSSFindMy.m for why it lives in Messages.
TWEAK_NAME = LSSFindMy
LSSFindMy_FILES = tweak/LSSFindMy.m
LSSFindMy_CFLAGS = -fobjc-arc
LSSFindMy_FRAMEWORKS = Foundation CoreLocation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# Tailscale, so the phone can expose itself over Funnel without an SSH-forward
# relay box. Built from source on demand and dropped into the package; the 58MB
# of binaries stay out of git. Needs `go` on PATH. See README.
TAILSCALE_VERSION = v1.104.5
# Per scheme because the shim path is patched in.
TS_BIN = .tailscale/$(TAILSCALE_VERSION)/$(or $(THEOS_PACKAGE_SCHEME),rootful)
LDID ?= $(THEOS)/toolchain/linux/iphone/bin/ldid

# Theos moves this under /var/jb itself for rootless.
after-stage:: $(TS_BIN)/tailscaled $(TS_BIN)/tailscale
	mkdir -p $(THEOS_STAGING_DIR)/usr/local/bin
	cp $^ $(THEOS_STAGING_DIR)/usr/local/bin/

$(TS_BIN)/%:
	@command -v go >/dev/null || { echo "error: go not on PATH, needed to build $*"; exit 1; }
	# -w is load-bearing, not just size: iOS's dyld rejects Go's __DWARF segment
	# ("filesize is larger than vmsize") and the binary won't exec at all.
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go install -ldflags="-s -w" tailscale.com/cmd/$*@$(TAILSCALE_VERSION)
	@mkdir -p $(TS_BIN)
	@# ~80MB per version; keep only the current one.
	find .tailscale -mindepth 1 -maxdepth 1 ! -name $(TAILSCALE_VERSION) -exec rm -rf {} +
	cp "$$(go env GOPATH)/bin/darwin_arm64/$*" $@
	PREFIX=$(THEOS_PACKAGE_INSTALL_PREFIX) python3 tools/ios_platform.py $@
	$(LDID) -S $@

# Rootless (THEOS_PACKAGE_SCHEME=rootless): prefix the paths in the staged
# plists and scripts. Rootful copies stay untouched, since a rootful device can
# have a stale /var/jb. Depending on DEBIAN/control runs this after staging.
LSS_SCRIPTS = $(addprefix $(THEOS_STAGING_DIR)/DEBIAN/,postinst prerm postrm)
ifneq ($(THEOS_PACKAGE_INSTALL_PREFIX),)
before-package:: $(THEOS_STAGING_DIR)/DEBIAN/control
	sed -i -e 's#\(/usr/libexec/\|/usr/local/bin/\|/Library/LaunchDaemons/\)#$(THEOS_PACKAGE_INSTALL_PREFIX)\1#g' \
		$(LSS_SCRIPTS) $(THEOS_STAGING_DIR)/Library/LaunchDaemons/*.plist
	sed -i -e '1s#^\#!/bin/bash#\#!$(THEOS_PACKAGE_INSTALL_PREFIX)/bin/sh#' \
		-e '1a export PATH=$(THEOS_PACKAGE_INSTALL_PREFIX)/usr/bin:$(THEOS_PACKAGE_INSTALL_PREFIX)/bin:$(THEOS_PACKAGE_INSTALL_PREFIX)/usr/sbin:$(THEOS_PACKAGE_INSTALL_PREFIX)/sbin:$$PATH' \
		$(LSS_SCRIPTS)
	sed -i 's#^exit 0$$#uicache -p $(THEOS_PACKAGE_INSTALL_PREFIX)/Applications/LocationSpoofServer.app || true\nexit 0#' \
		$(THEOS_STAGING_DIR)/DEBIAN/postinst
endif

# Daemon loading lives in layout/DEBIAN/postinst, so a Sileo install gets it
# too; dpkg runs that for `make install` as well. Nothing to repeat here.
after-install::
	@echo ""
	@echo "  Not logged into Tailscale yet: open LocationSpoofServer on the"
	@echo "  phone and tap 'Log in to Tailscale'."
	@echo ""
