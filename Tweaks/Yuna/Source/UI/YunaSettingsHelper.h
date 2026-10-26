#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../Headers/YunaCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface YunaSettingsHelper : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSInteger maxItems;
@property (nonatomic, assign) NSInteger numberOfRows;
@property (nonatomic, assign) CGFloat rowHeight;
@property (nonatomic, assign) BOOL saveImages;
@property (nonatomic, assign) BOOL saveFiles;
@property (nonatomic, assign) YunaHapticLevel hapticFeedback;
@property (nonatomic, assign) BOOL autoDismissOnPaste;
@property (nonatomic, assign) YunaDockPosition dockPosition;

+ (instancetype)sharedHelper;
- (void)reloadSettings;
- (void)triggerHapticFeedback;

@end

NS_ASSUME_NONNULL_END
