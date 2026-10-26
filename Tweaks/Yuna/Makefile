TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := SpringBoard
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Yuna

Yuna_FILES = $(wildcard Source/*.x Source/*.m Source/UI/*.m)
Yuna_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Iinclude -ISource/Headers
Yuna_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
Yuna_LIBRARIES = ellekit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
