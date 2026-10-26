#import "YunaSettingsHelper.h"
#import <notify.h>

@implementation YunaSettingsHelper

+ (instancetype)sharedHelper {
    static YunaSettingsHelper *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[YunaSettingsHelper alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadDefaults];
        [self reloadSettings];
        [self registerForNotifications];
    }
    return self;
}

- (void)loadDefaults {
    _enabled = YES;
    _maxItems = 30;
    _numberOfRows = 2; // Default 2 rows
    _rowHeight = 52.0;
    _saveImages = YES;
    _saveFiles = YES;
    _hapticFeedback = YunaHapticLevelLight;
    _autoDismissOnPaste = YES;
    _dockPosition = YunaDockPositionNextToDictation;
}

- (void)registerForNotifications {
    int notifyToken;
    notify_register_dispatch(YUNA_PREFS_NOTIFICATION, &notifyToken, dispatch_get_main_queue(), ^(int token) {
        [self reloadSettings];
    });
}

- (void)reloadSettings {
    CFPreferencesAppSynchronize((CFStringRef)YUNA_BUNDLE_ID);
    NSString *path = YUNA_PREFS_FILE;
    NSMutableDictionary *prefs = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!prefs) {
        prefs = [NSMutableDictionary dictionary];
    }
    
    // Supplement from CFPreferences if file sync is delayed
    NSArray *keys = @[@"enabled", @"maxItems", @"numberOfRows", @"rowHeight", @"saveImages", @"saveFiles", @"hapticFeedback", @"autoDismissOnPaste", @"dockPosition"];
    for (NSString *k in keys) {
        if (prefs[k] == nil) {
            CFPropertyListRef val = CFPreferencesCopyAppValue((CFStringRef)k, (CFStringRef)YUNA_BUNDLE_ID);
            if (val) {
                prefs[k] = (__bridge id)val;
                CFRelease(val);
            }
        }
    }
    
    if (prefs) {
        if (prefs[@"enabled"] != nil) {
            _enabled = [prefs[@"enabled"] boolValue];
        }
        if (prefs[@"maxItems"] != nil) {
            _maxItems = [prefs[@"maxItems"] integerValue];
            if (_maxItems < 5) _maxItems = 5;
            if (_maxItems > 200) _maxItems = 200;
        }
        if (prefs[@"numberOfRows"] != nil) {
            _numberOfRows = [prefs[@"numberOfRows"] integerValue];
            if (_numberOfRows < 1) _numberOfRows = 1;
            if (_numberOfRows > 4) _numberOfRows = 4;
        }
        if (prefs[@"rowHeight"] != nil) {
            _rowHeight = [prefs[@"rowHeight"] floatValue];
            if (_rowHeight < 36.0) _rowHeight = 36.0;
            if (_rowHeight > 90.0) _rowHeight = 90.0;
        }
        if (prefs[@"saveImages"] != nil) {
            _saveImages = [prefs[@"saveImages"] boolValue];
        }
        if (prefs[@"saveFiles"] != nil) {
            _saveFiles = [prefs[@"saveFiles"] boolValue];
        }
        if (prefs[@"hapticFeedback"] != nil) {
            _hapticFeedback = (YunaHapticLevel)[prefs[@"hapticFeedback"] integerValue];
        }
        if (prefs[@"autoDismissOnPaste"] != nil) {
            _autoDismissOnPaste = [prefs[@"autoDismissOnPaste"] boolValue];
        }
        if (prefs[@"dockPosition"] != nil) {
            _dockPosition = (YunaDockPosition)[prefs[@"dockPosition"] integerValue];
        }
    }
}

- (void)triggerHapticFeedback {
    if (_hapticFeedback == YunaHapticLevelNone) return;
    
    UIImpactFeedbackStyle style = UIImpactFeedbackStyleLight;
    switch (_hapticFeedback) {
        case YunaHapticLevelMedium:
            style = UIImpactFeedbackStyleMedium;
            break;
        case YunaHapticLevelHeavy:
            style = UIImpactFeedbackStyleHeavy;
            break;
        case YunaHapticLevelLight:
        default:
            style = UIImpactFeedbackStyleLight;
            break;
    }
    
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen prepare];
    [gen impactOccurred];
}

@end
