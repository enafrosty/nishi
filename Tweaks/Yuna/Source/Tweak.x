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
static __weak YunaPanelView *kYunaActivePanel = nil;

static UIView *yna_extractDockItemView(id dockItem) {
    if (!dockItem) return nil;
    if ([dockItem respondsToSelector:@selector(button)]) {
        id btn = [dockItem performSelector:@selector(button)];
        if ([btn isKindOfClass:[UIView class]]) {
            return (UIView *)btn;
        }
    }
    if ([dockItem respondsToSelector:@selector(view)]) {
        id v = [dockItem performSelector:@selector(view)];
        if ([v isKindOfClass:[UIView class]]) {
            return (UIView *)v;
        }
    }
    return nil;
}

@interface UIKeyboardDockView (Yuna) <YunaDockButtonDelegate, YunaPanelViewDelegate>
@property (nonatomic, strong, nullable) YunaDockButton *yunaDockButton;
@property (nonatomic, strong, nullable) YunaPanelView *yunaPanelView;
- (void)yna_layoutDockButton;
- (void)yna_registerPrefsObserver;
- (void)yna_syncCurrentPasteboard;
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

static inline BOOL yna_isSpringBoardProcess(void) {
    static BOOL isSB = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        isSB = [bid isEqualToString:@"com.apple.springboard"];
    });
    return isSB;
}

static void yna_dispatchItemToIPC(YunaItem *item) {
    if (!item) return;
    @autoreleasepool {
        YunaSettingsHelper *settings = [YunaSettingsHelper sharedHelper];
        if (!settings.enabled) return;
        
        if (item.type == YunaItemTypeImage && !settings.saveImages) return;
        if (item.type == YunaItemTypeFile && !settings.saveFiles) return;
        
        // Add to local memory for instant 0ms latency in current process's keyboard dock
        [[YunaStorage sharedInstance] addItem:item];
        
        if (yna_isSpringBoardProcess()) {
            return;
        }
        
        // Sandboxed client app: serialize and transmit to SpringBoard via custom named IPC pasteboard
        NSDictionary *dict = [item dictionaryRepresentation];
        if (!dict) return;
        
        NSError *err = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:&err];
        if (!data || data.length == 0) return;
        
        UIPasteboard *ipcPB = [UIPasteboard pasteboardWithName:YUNA_IPC_PASTEBOARD_NAME create:YES];
        if (ipcPB) {
            [ipcPB setData:data forPasteboardType:YUNA_IPC_ITEM_TYPE];
            notify_post(YUNA_EXT_PASTEBOARD_NOTIFICATION);
        }
    }
}

static YunaItem *yna_extractItemFromItemsArray(NSArray *items) {
    if (!items || items.count == 0) return nil;
    for (id itemObj in items) {
        if (![itemObj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = (NSDictionary *)itemObj;
        
        // 1. Text
        for (NSString *key in @[@"public.utf8-plain-text", @"public.plain-text", @"NSStringPboardType"]) {
            id val = dict[key];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                return [YunaItem itemWithText:(NSString *)val];
            } else if ([val isKindOfClass:[NSData class]]) {
                NSString *str = [[NSString alloc] initWithData:(NSData *)val encoding:NSUTF8StringEncoding];
                if (str && str.length > 0) {
                    return [YunaItem itemWithText:str];
                }
            }
        }
        
        // 2. URL
        for (NSString *key in @[@"public.url", @"NSURLPboardType"]) {
            id val = dict[key];
            if ([val isKindOfClass:[NSURL class]]) {
                return [YunaItem itemWithURL:(NSURL *)val];
            } else if ([val isKindOfClass:[NSString class]]) {
                NSURL *u = [NSURL URLWithString:(NSString *)val];
                if (u && u.host) return [YunaItem itemWithURL:u];
            }
        }
        
        // 3. Image
        for (NSString *key in @[@"public.png", @"public.jpeg", @"public.tiff"]) {
            id val = dict[key];
            if ([val isKindOfClass:[UIImage class]]) {
                return [YunaItem itemWithImage:(UIImage *)val];
            } else if ([val isKindOfClass:[NSData class]]) {
                UIImage *img = [UIImage imageWithData:(NSData *)val];
                if (img) return [YunaItem itemWithImage:img];
            }
        }
    }
    return nil;
}

%hook UIKeyboardLayoutStar

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (kYunaActivePanel && kYunaActivePanel.superview && !kYunaActivePanel.hidden && kYunaActivePanel.alpha > 0.05) {
        CGPoint pInPanel = [self convertPoint:point toView:kYunaActivePanel];
        if ([kYunaActivePanel pointInside:pInPanel withEvent:event]) {
            // Forward hit-testing directly into Yuna panel and its interactive controls (cells, pin buttons, close button)
            UIView *hit = [kYunaActivePanel hitTest:pInPanel withEvent:event];
            return hit ?: kYunaActivePanel;
        }
    }
    return %orig;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (kYunaActivePanel && kYunaActivePanel.superview && !kYunaActivePanel.hidden && kYunaActivePanel.alpha > 0.05) {
        CGPoint p = [gestureRecognizer locationInView:kYunaActivePanel];
        if ([kYunaActivePanel pointInside:p withEvent:nil]) {
            return NO; // Prevent keyboard gesture recognizers from stealing or cancelling Yuna touches
        }
    }
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (kYunaActivePanel && kYunaActivePanel.superview && !kYunaActivePanel.hidden && kYunaActivePanel.alpha > 0.05) {
        CGPoint p = [touch locationInView:kYunaActivePanel];
        if ([kYunaActivePanel pointInside:p withEvent:nil]) {
            return NO; // Prevent keyboard gesture recognizers from stealing or cancelling Yuna touches
        }
    }
    return %orig;
}

%end

%hook UIPasteboard

- (void)setString:(NSString *)string {
    %orig;
    if (string && string.length > 0) {
        yna_dispatchItemToIPC([YunaItem itemWithText:string]);
    }
}

- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig;
    if (strings.firstObject && strings.firstObject.length > 0) {
        yna_dispatchItemToIPC([YunaItem itemWithText:strings.firstObject]);
    }
}

- (void)setImage:(UIImage *)image {
    %orig;
    if (image) {
        yna_dispatchItemToIPC([YunaItem itemWithImage:image]);
    }
}

- (void)setImages:(NSArray<UIImage *> *)images {
    %orig;
    if (images.firstObject) {
        yna_dispatchItemToIPC([YunaItem itemWithImage:images.firstObject]);
    }
}

- (void)setURL:(NSURL *)url {
    %orig;
    if (url) {
        if ([url isFileURL]) {
            NSNumber *fileSize = nil;
            [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            yna_dispatchItemToIPC([YunaItem itemWithFileURL:url size:[fileSize unsignedIntegerValue]]);
        } else {
            yna_dispatchItemToIPC([YunaItem itemWithURL:url]);
        }
    }
}

- (void)setURLs:(NSArray<NSURL *> *)urls {
    %orig;
    if (urls.firstObject) {
        NSURL *url = urls.firstObject;
        if ([url isFileURL]) {
            NSNumber *fileSize = nil;
            [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            yna_dispatchItemToIPC([YunaItem itemWithFileURL:url size:[fileSize unsignedIntegerValue]]);
        } else {
            yna_dispatchItemToIPC([YunaItem itemWithURL:url]);
        }
    }
}

- (void)setItems:(NSArray *)items {
    %orig;
    YunaItem *item = yna_extractItemFromItemsArray(items);
    if (item) {
        yna_dispatchItemToIPC(item);
    }
}

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    YunaItem *item = yna_extractItemFromItemsArray(items);
    if (item) {
        yna_dispatchItemToIPC(item);
    }
}

- (void)setValue:(id)value forPasteboardType:(NSString *)pasteboardType {
    %orig;
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        yna_dispatchItemToIPC([YunaItem itemWithText:(NSString *)value]);
    } else if ([value isKindOfClass:[NSURL class]]) {
        yna_dispatchItemToIPC([YunaItem itemWithURL:(NSURL *)value]);
    } else if ([value isKindOfClass:[UIImage class]]) {
        yna_dispatchItemToIPC([YunaItem itemWithImage:(UIImage *)value]);
    }
}

- (void)setData:(NSData *)data forPasteboardType:(NSString *)pasteboardType {
    %orig;
    if (data && data.length > 0 && ([pasteboardType containsString:@"text"] || [pasteboardType containsString:@"string"] || [pasteboardType containsString:@"plain"])) {
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (str && str.length > 0) {
            yna_dispatchItemToIPC([YunaItem itemWithText:str]);
        }
    }
}

- (void)setObjects:(NSArray *)objects {
    %orig;
    for (id obj in objects) {
        if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length] > 0) {
            yna_dispatchItemToIPC([YunaItem itemWithText:(NSString *)obj]);
            break;
        } else if ([obj isKindOfClass:[NSURL class]]) {
            yna_dispatchItemToIPC([YunaItem itemWithURL:(NSURL *)obj]);
            break;
        } else if ([obj isKindOfClass:[UIImage class]]) {
            yna_dispatchItemToIPC([YunaItem itemWithImage:(UIImage *)obj]);
            break;
        }
    }
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
    
    YunaPanelView *existingPanel = objc_getAssociatedObject(self, &kYunaPanelViewKey);
    if (existingPanel && existingPanel.superview) {
        [existingPanel.superview bringSubviewToFront:existingPanel];
    }
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
    
    // Resolve left dock item view (language / globe switcher or emoji button)
    UIView *leftBtn = nil;
    if ([self respondsToSelector:@selector(leftDockItem)]) {
        leftBtn = yna_extractDockItemView([self leftDockItem]);
    }
    
    // Resolve right dock item view (dictation microphone)
    UIView *rightBtn = nil;
    if ([self respondsToSelector:@selector(rightDockItem)]) {
        rightBtn = yna_extractDockItemView([self rightDockItem]);
    }
    
    // Search self.subviews for dock buttons if dockItems were not resolved
    if (!leftBtn || !rightBtn) {
        for (UIView *sub in self.subviews) {
            if (sub == btn) continue;
            if (![sub isKindOfClass:[UIButton class]] &&
                ![NSStringFromClass([sub class]) containsString:@"Button"] &&
                ![NSStringFromClass([sub class]) containsString:@"Item"]) {
                continue;
            }
            if (!leftBtn || sub.frame.origin.x < leftBtn.frame.origin.x) {
                leftBtn = sub;
            }
            if (!rightBtn || sub.frame.origin.x > rightBtn.frame.origin.x) {
                rightBtn = sub;
            }
        }
    }
    
    BOOL isLeftBtnValid = (leftBtn != nil && !leftBtn.hidden && leftBtn.frame.size.height > 5.0);
    BOOL isRightBtnVisible = (rightBtn != nil && rightBtn != leftBtn && !rightBtn.hidden &&
                              rightBtn.alpha > 0.05 && rightBtn.frame.size.width > 5.0 &&
                              rightBtn.frame.origin.x > (bounds.size.width / 2.0));
    
    CGFloat btnW = (isLeftBtnValid && leftBtn.frame.size.width >= 32.0) ? leftBtn.frame.size.width : 44.0;
    CGFloat btnH = (isLeftBtnValid && leftBtn.frame.size.height >= 32.0) ? leftBtn.frame.size.height : 44.0;
    
    // Vertically align directly with the language button switcher on the bottom dock row
    CGFloat targetYCenter = 0.0;
    if (isLeftBtnValid) {
        targetYCenter = leftBtn.center.y;
    } else if (isRightBtnVisible) {
        targetYCenter = rightBtn.center.y;
    } else {
        CGFloat bottomMargin = 10.0;
        if (@available(iOS 11.0, *)) {
            if (self.safeAreaInsets.bottom > 0) {
                bottomMargin = self.safeAreaInsets.bottom + 2.0;
            }
        }
        targetYCenter = bounds.size.height - (btnH / 2.0) - bottomMargin;
    }
    
    // Horizontally position on the right side of the keyboard or next to dictation
    CGFloat targetXCenter = 0.0;
    switch (settings.dockPosition) {
        case YunaDockPositionNextToDictation: {
            if (isRightBtnVisible) {
                targetXCenter = rightBtn.frame.origin.x - (btnW / 2.0) - 6.0;
            } else {
                // When dictation is disabled, take the right dock slot opposite the language switcher
                CGFloat leftMargin = isLeftBtnValid ? leftBtn.center.x : (btnW / 2.0 + 14.0);
                targetXCenter = bounds.size.width - leftMargin;
            }
            break;
        }
        case YunaDockPositionNextToEmoji: {
            if (isLeftBtnValid) {
                targetXCenter = CGRectGetMaxX(leftBtn.frame) + 6.0 + (btnW / 2.0);
            } else {
                targetXCenter = 14.0 + (btnW / 2.0);
            }
            break;
        }
        case YunaDockPositionCenter:
        default: {
            targetXCenter = bounds.size.width / 2.0;
            break;
        }
    }
    
    btn.bounds = CGRectMake(0, 0, btnW, btnH);
    btn.center = CGPointMake(targetXCenter, targetYCenter);
    [self bringSubviewToFront:btn];
}

%new
- (void)yna_syncCurrentPasteboard {
    @autoreleasepool {
        [[YunaStorage sharedInstance] reloadFromDisk];
    }
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
    
    // Synchronize latest clipboard content into storage before presenting
    [self yna_syncCurrentPasteboard];
    
    CGFloat dockH = self.bounds.size.height;
    CGFloat targetH = container.bounds.size.height - dockH;
    if (targetH < 180.0) {
        targetH = 220.0;
    }
    CGRect panelFrame = CGRectMake(0, 0, container.bounds.size.width, targetH);
    
    panel = [YunaPanelView panelViewWithFrame:panelFrame];
    panel.delegate = (id<YunaPanelViewDelegate>)self;
    objc_setAssociatedObject(self, &kYunaPanelViewKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    kYunaActivePanel = panel;
    
    [panel presentInView:container];
}

%new
- (void)yunaPanelViewDidRequestDismiss:(UIView *)panelView {
    if (kYunaActivePanel == panelView) {
        kYunaActivePanel = nil;
    }
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
        }
        %init(KeyboardHooks);
    }
}
