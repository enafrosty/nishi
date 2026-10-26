TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = YunaPrefs

YunaPrefs_FILES = Source/YNARootListController.m ../Source/YunaStorage.m ../Source/YunaItem.m
YunaPrefs_INSTALL_PATH = /Library/PreferenceBundles
YunaPrefs_FRAMEWORKS = UIKit
YunaPrefs_PRIVATE_FRAMEWORKS = Preferences
YunaPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I../Source -I../Source/Headers -I../Source/UI -I../../../include -I../../include -Iinclude

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Yuna.plist$(ECHO_END)
