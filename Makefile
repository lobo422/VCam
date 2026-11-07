THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCam

VCam_FILES = Tweak.xm MediaManager.m
VCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error=deprecated-declarations
VCam_CXXFLAGS = -fobjc-arc -std=c++17 -Wno-deprecated-declarations -Wno-error=deprecated-declarations
VCam_LDFLAGS = -std=c++17
VCam_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreImage MobileCoreServices ImageIO QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Camera 2>/dev/null || true"
