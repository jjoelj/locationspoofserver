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

TOOL_NAME = locationspoofd fmfwatchd
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

include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "launchctl unload /Library/LaunchDaemons/app.bluebubbles.fmfwatchd.plist 2>/dev/null || true"
	install.exec "launchctl load /Library/LaunchDaemons/app.bluebubbles.fmfwatchd.plist"
	install.exec "launchctl start app.bluebubbles.fmfwatchd || true"
	install.exec "launchctl unload /Library/LaunchDaemons/app.bluebubbles.locationspoofd.plist 2>/dev/null || true"
	install.exec "launchctl load /Library/LaunchDaemons/app.bluebubbles.locationspoofd.plist"
	install.exec "launchctl start app.bluebubbles.locationspoofd || true"
