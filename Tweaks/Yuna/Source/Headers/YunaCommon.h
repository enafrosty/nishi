#ifndef YUNA_COMMON_H
#define YUNA_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../../../include/rootless.h"

#define YUNA_BUNDLE_ID @"com.frosty.yuna"
#define YUNA_PREFS_NOTIFICATION "com.frosty.yuna/ReloadPrefs"
#define YUNA_CLIPBOARD_NOTIFICATION "com.frosty.yuna/ClipboardChanged"
#define YUNA_EXT_PASTEBOARD_NOTIFICATION "com.frosty.yuna/SystemPasteboardChanged"

#define YUNA_STORAGE_PATH [NSString stringWithUTF8String:JBROOT_PATH("/Library/Application Support/Yuna")]
#define YUNA_HISTORY_FILE [YUNA_STORAGE_PATH stringByAppendingPathComponent:@"history.plist"]
#define YUNA_IMAGES_DIR [YUNA_STORAGE_PATH stringByAppendingPathComponent:@"Images"]
#define YUNA_PREFS_FILE @"/var/mobile/Library/Preferences/com.frosty.yuna.plist"

#ifdef DEBUG
#define YunaLog(fmt, ...) NSLog(@"[Yuna:DEBUG] " fmt, ##__VA_ARGS__)
#else
#define YunaLog(fmt, ...) NSLog(@"[Yuna] " fmt, ##__VA_ARGS__)
#endif

typedef NS_ENUM(NSInteger, YunaItemType) {
    YunaItemTypeText = 0,
    YunaItemTypeImage = 1,
    YunaItemTypeURL = 2,
    YunaItemTypeFile = 3
};

typedef NS_ENUM(NSInteger, YunaHapticLevel) {
    YunaHapticLevelNone = 0,
    YunaHapticLevelLight = 1,
    YunaHapticLevelMedium = 2,
    YunaHapticLevelHeavy = 3
};

typedef NS_ENUM(NSInteger, YunaDockPosition) {
    YunaDockPositionNextToDictation = 0,
    YunaDockPositionCenter = 1,
    YunaDockPositionNextToEmoji = 2
};

#endif /* YUNA_COMMON_H */
