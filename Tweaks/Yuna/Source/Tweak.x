#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "Headers/UIKeyboardPrivate.h"
#import "Headers/YunaCommon.h"
#import "YunaServer.h"
#import "YunaStorage.h"
#import "UI/YunaDockButton.h"
#import "UI/YunaPanelView.h"
#import "UI/YunaSettingsHelper.h"

static const char kYunaDockButtonKey;
static const char kYunaPanelViewKey;
static const char kYunaPrefsTokenKey;

@interface UIKeyboardDockView (Yuna) <YunaDockButtonDelegate, YunaPanelViewDelegate>
@property (nonatomic, strong, nullable) YunaDockButton *yunaDockButton;
@property (nonatomic, strong, nullable) YunaPanelView *yunaPanelView;
- (void)yna_layoutDockButton;
- (void)yna_registerPrefsObserver;
@end

%group SpringBoardHooks

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    YunaLog(@"SpringBoard launched, initializing Yuna clipboard daemon");
    [[YunaServer sharedServer] startServer];
}

%end

%end // SpringBoardHooks

%group KeyboardHooks

%hook UIPasteboard

- (void)setString:(NSString *)string {
    %orig;
    notify_post(YUNA_EXT_PASTEBOARD_NOTIFICATION);
}

- (void)setImage:(UIImage *)image {
    %orig;
    notify_post(YUNA_EXT_PASTEBOARD_NOTIFICATION);
}

- (void)setURL:(NSURL *)url {
    %orig;
    notify_post(YUNA_EXT_PASTEBOARD_NOTIFICATION);
}

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    notify_post(YUNA_EXT_PASTEBOARD_NOTIFICATION);
}

%end

%hook UIKeyboardDockView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self yna_registerPrefsObserver];
    }
}

- (void)layoutSubviews {
    %orig;
    
    YunaSettingsHelper *settings = [YunaSettingsHelper sharedHelper];
    if (!settings.enabled) {
        YunaDockButton *existingBtn = objc_getAssociatedObject(self, &kYunaDockButtonKey);
        if (existingBtn) {
            [existingBtn removeFromSuperview];
            objc_setAssociatedObject(self, &kYunaDockButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    
    [self yna_layoutDockButton];
}

%new
- (void)yna_registerPrefsObserver {
    NSNumber *tokenNum = objc_getAssociatedObject(self, &kYunaPrefsTokenKey);
    if (tokenNum) return;
    
    int token = 0;
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(YUNA_PREFS_NOTIFICATION, &token, dispatch_get_main_queue(), ^(int t) {
        [weakSelf setNeedsLayout];
    });
    objc_setAssociatedObject(self, &kYunaPrefsTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)yna_layoutDockButton {
    YunaSettingsHelper *settings = [YunaSettingsHelper sharedHelper];
    YunaDockButton *btn = objc_getAssociatedObject(self, &kYunaDockButtonKey);
    
    if (!btn) {
        btn = [YunaDockButton dockButton];
        btn.delegate = (id<YunaDockButtonDelegate>)self;
        objc_setAssociatedObject(self, &kYunaDockButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:btn];
    }
    
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    
    CGFloat btnW = 44.0;
    CGFloat btnH = 44.0;
    CGFloat yPos = (bounds.size.height - btnH) / 2.0;
    CGFloat xPos = 0.0;
    
    switch (settings.dockPosition) {
        case YunaDockPositionNextToDictation: {
            UIView *rightBtn = nil;
            if ([self respondsToSelector:@selector(rightDockItem)]) {
                UIKeyboardDockItem *rItem = [self rightDockItem];
                if (rItem && [rItem respondsToSelector:@selector(button)]) {
                    rightBtn = [rItem button];
                }
            }
            if (rightBtn && rightBtn.frame.origin.x > 0 && !rightBtn.hidden) {
                xPos = rightBtn.frame.origin.x - btnW - 6.0;
            } else {
                xPos = bounds.size.width - btnW - 12.0;
            }
            break;
        }
        case YunaDockPositionNextToEmoji: {
            UIView *leftBtn = nil;
            if ([self respondsToSelector:@selector(leftDockItem)]) {
                UIKeyboardDockItem *lItem = [self leftDockItem];
                if (lItem && [lItem respondsToSelector:@selector(button)]) {
                    leftBtn = [lItem button];
                }
            }
            if (leftBtn && leftBtn.frame.origin.x >= 0 && !leftBtn.hidden) {
                xPos = CGRectGetMaxX(leftBtn.frame) + 6.0;
            } else {
                xPos = 12.0;
            }
            break;
        }
        case YunaDockPositionCenter:
        default: {
            xPos = (bounds.size.width - btnW) / 2.0;
            break;
        }
    }
    
    btn.frame = CGRectMake(xPos, yPos, btnW, btnH);
    [self bringSubviewToFront:btn];
}

%new
- (void)yunaDockButtonDidTap:(UIButton *)button {
    UIView *container = self.superview;
    if (!container) return;
    
    // Avoid presenting duplicate panel
    YunaPanelView *panel = objc_getAssociatedObject(self, &kYunaPanelViewKey);
    if (panel && panel.superview) {
        [panel dismissAnimated:YES];
        return;
    }
    
    CGFloat dockH = self.bounds.size.height;
    CGFloat targetH = container.bounds.size.height - dockH;
    if (targetH < 180.0) {
        targetH = 220.0;
    }
    CGRect panelFrame = CGRectMake(0, 0, container.bounds.size.width, targetH);
    
    panel = [YunaPanelView panelViewWithFrame:panelFrame];
    panel.delegate = (id<YunaPanelViewDelegate>)self;
    objc_setAssociatedObject(self, &kYunaPanelViewKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [panel presentInView:container];
}

%new
- (void)yunaPanelViewDidRequestDismiss:(UIView *)panelView {
    objc_setAssociatedObject(self, &kYunaPanelViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%end // KeyboardHooks

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID) return;
        
        // Exclude system background daemons that link UIKit but are not interactive
        NSArray *excludedPrefixes = @[
            @"com.apple.WebKit",
            @"com.apple.CoreAuthUI",
            @"com.apple.quicklook",
            @"com.apple.diagnosticextensions",
            @"com.apple.PassbookUIService"
        ];
        
        for (NSString *prefix in excludedPrefixes) {
            if ([bundleID hasPrefix:prefix]) {
                return;
            }
        }
        
        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(SpringBoardHooks);
            %init(KeyboardHooks);
        } else {
            // Standard GUI application
            %init(KeyboardHooks);
        }
    }
}
