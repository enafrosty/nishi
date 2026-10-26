TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES := SpringBoard
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += Tweaks/Yuna

include $(THEOS_MAKE_PATH)/aggregate.mk
