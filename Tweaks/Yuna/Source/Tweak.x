#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <math.h>
#import "Headers/UIKeyboardPrivate.h"
#import "Headers/YunaCommon.h"
#import "YunaServer.h"
#import "YunaStorage.h"
#import "UI/YunaDockButton.h"
#import "UI/YunaPanelView.h"
#import "UI/YunaSettingsHelper.h"

static const char kYunaDockButtonKey;
static const char kYunaPanelViewKey;
static __weak YunaPanelView *kYunaActivePanel = nil;
static __weak UIKeyboardDockView *kYunaActiveDockView = nil;
static _Thread_local BOOL kYunaInPasteboardHook = NO;

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

static dispatch_queue_t yna_captureQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.frosty.yuna.capture", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static inline BOOL yna_isGeneralPasteboard(UIPasteboard *pb) {
    if (!pb) return NO;
    NSString *name = pb.name;
    if (!name) return NO;
    return ([name isEqualToString:UIPasteboardNameGeneral] ||
            [name isEqualToString:@"com.apple.UIKit.pboard.general"]);
}

static void yna_commitItemAsync(YunaItem * (^itemBuilder)(void)) {
    if (!itemBuilder) return;
    dispatch_async(yna_captureQueue(), ^{
        @autoreleasepool {
            YunaSettingsHelper *settings = [YunaSettingsHelper sharedHelper];
            if (!settings.enabled) return;

            YunaItem *item = itemBuilder();
            if (!item) return;

            if (item.type == YunaItemTypeImage && !settings.saveImages) return;
            if (item.type == YunaItemTypeFile && !settings.saveFiles) return;

            [[YunaStorage sharedInstance] addItem:item];
        }
    });
}

static void yna_captureText(NSString *text) {
    if (!text || text.length == 0) return;
    NSString *textCopy = [text copy];
    yna_commitItemAsync(^YunaItem *{
        return [YunaItem itemWithText:textCopy];
    });
}

static void yna_captureURL(NSURL *url) {
    if (!url) return;
    NSURL *urlCopy = [url copy];
    yna_commitItemAsync(^YunaItem *{
        if ([urlCopy isFileURL]) {
            NSNumber *fileSize = nil;
            [urlCopy getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            return [YunaItem itemWithFileURL:urlCopy size:[fileSize unsignedIntegerValue]];
        }
        return [YunaItem itemWithURL:urlCopy];
    });
}

static void yna_captureImage(UIImage *image) {
    if (!image) return;
    yna_commitItemAsync(^YunaItem *{
        return [YunaItem itemWithImage:image];
    });
}

static void yna_captureImageData(NSData *imageData) {
    if (!imageData || imageData.length == 0) return;
    NSData *dataCopy = [imageData copy];
    yna_commitItemAsync(^YunaItem *{
        UIImage *img = [UIImage imageWithData:dataCopy];
        return img ? [YunaItem itemWithImage:img] : nil;
    });
}

static BOOL yna_dispatchFromItemsArray(NSArray *items) {
    if (!items || items.count == 0) return NO;
    for (id itemObj in items) {
        if (![itemObj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = (NSDictionary *)itemObj;

        // 1. Text / Rich Text
        for (NSString *key in @[@"public.utf8-plain-text", @"public.plain-text", @"NSStringPboardType"]) {
            id val = dict[key];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                yna_captureText((NSString *)val);
                return YES;
            } else if ([val isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)val length] > 0) {
                yna_captureText([(NSAttributedString *)val string]);
                return YES;
            } else if ([val isKindOfClass:[NSData class]] && [(NSData *)val length] > 0) {
                NSString *str = [[NSString alloc] initWithData:(NSData *)val encoding:NSUTF8StringEncoding];
                if (str && str.length > 0) {
                    yna_captureText(str);
                    return YES;
                }
            }
        }

        // 2. URL
        for (NSString *key in @[@"public.url", @"public.file-url", @"NSURLPboardType"]) {
            id val = dict[key];
            if ([val isKindOfClass:[NSURL class]]) {
                yna_captureURL((NSURL *)val);
                return YES;
            } else if ([val isKindOfClass:[NSString class]]) {
                NSURL *u = [NSURL URLWithString:(NSString *)val];
                if (u && (u.host || u.isFileURL)) {
                    yna_captureURL(u);
                    return YES;
                }
            } else if ([val isKindOfClass:[NSData class]] && [(NSData *)val length] > 0) {
                NSString *urlStr = [[NSString alloc] initWithData:(NSData *)val encoding:NSUTF8StringEncoding];
                if (urlStr && urlStr.length > 0) {
                    NSURL *u = [NSURL URLWithString:urlStr];
                    if (u && (u.host || u.isFileURL)) {
                        yna_captureURL(u);
                        return YES;
                    }
                }
            }
        }

        // 3. Image
        for (NSString *key in @[@"public.png", @"public.jpeg", @"public.tiff", @"public.heic"]) {
            id val = dict[key];
            if ([val isKindOfClass:[UIImage class]]) {
                yna_captureImage((UIImage *)val);
                return YES;
            } else if ([val isKindOfClass:[NSData class]] && [(NSData *)val length] > 0) {
                yna_captureImageData((NSData *)val);
                return YES;
            }
        }
    }
    return NO;
}

static void yna_captureFromItemProviders(NSArray<NSItemProvider *> *providers) {
    if (!providers || providers.count == 0) return;
    NSItemProvider *provider = providers.firstObject;
    if (![provider isKindOfClass:[NSItemProvider class]]) return;

    if ([provider hasItemConformingToTypeIdentifier:@"public.image"] &&
        [provider canLoadObjectOfClass:[UIImage class]]) {
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> _Nullable object, NSError * _Nullable error) {
            if ([object isKindOfClass:[UIImage class]]) {
                yna_captureImage((UIImage *)object);
            }
        }];
    } else if ([provider hasItemConformingToTypeIdentifier:@"public.url"] &&
               [provider canLoadObjectOfClass:[NSURL class]]) {
        [provider loadObjectOfClass:[NSURL class] completionHandler:^(id<NSItemProviderReading> _Nullable object, NSError * _Nullable error) {
            if ([object isKindOfClass:[NSURL class]]) {
                yna_captureURL((NSURL *)object);
            } else if ([provider canLoadObjectOfClass:[NSString class]]) {
                [provider loadObjectOfClass:[NSString class] completionHandler:^(id<NSItemProviderReading> _Nullable strObj, NSError * _Nullable err2) {
                    if ([strObj isKindOfClass:[NSString class]] && [(NSString *)strObj length] > 0) {
                        yna_captureText((NSString *)strObj);
                    }
                }];
            }
        }];
    } else if ([provider canLoadObjectOfClass:[NSString class]]) {
        [provider loadObjectOfClass:[NSString class] completionHandler:^(id<NSItemProviderReading> _Nullable object, NSError * _Nullable error) {
            if ([object isKindOfClass:[NSString class]] && [(NSString *)object length] > 0) {
                yna_captureText((NSString *)object);
            }
        }];
    } else if ([provider canLoadObjectOfClass:[NSAttributedString class]]) {
        [provider loadObjectOfClass:[NSAttributedString class] completionHandler:^(id<NSItemProviderReading> _Nullable object, NSError * _Nullable error) {
            if ([object isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)object length] > 0) {
                yna_captureText([(NSAttributedString *)object string]);
            }
        }];
    } else if ([provider hasItemConformingToTypeIdentifier:@"public.utf8-plain-text"]) {
        [provider loadDataRepresentationForTypeIdentifier:@"public.utf8-plain-text" completionHandler:^(NSData * _Nullable data, NSError * _Nullable error) {
            if (data && data.length > 0) {
                NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (str && str.length > 0) {
                    yna_captureText(str);
                }
            }
        }];
    } else if ([provider hasItemConformingToTypeIdentifier:@"public.plain-text"]) {
        [provider loadDataRepresentationForTypeIdentifier:@"public.plain-text" completionHandler:^(NSData * _Nullable data, NSError * _Nullable error) {
            if (data && data.length > 0) {
                NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (str && str.length > 0) {
                    yna_captureText(str);
                }
            }
        }];
    }
}

static void yna_captureFromObjectsArray(NSArray *objects) {
    if (!objects || objects.count == 0) return;
    for (id obj in objects) {
        if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length] > 0) {
            yna_captureText((NSString *)obj);
            break;
        } else if ([obj isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)obj length] > 0) {
            yna_captureText([(NSAttributedString *)obj string]);
            break;
        } else if ([obj isKindOfClass:[NSURL class]]) {
            yna_captureURL((NSURL *)obj);
            break;
        } else if ([obj isKindOfClass:[UIImage class]]) {
            yna_captureImage((UIImage *)obj);
            break;
        }
    }
}

%hook UIKeyboardLayoutStar

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (kYunaActivePanel && kYunaActivePanel.superview && !kYunaActivePanel.hidden && kYunaActivePanel.alpha > 0.05) {
        CGPoint pInPanel = [self convertPoint:point toView:kYunaActivePanel];
        if ([kYunaActivePanel pointInside:pInPanel withEvent:event]) {
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
            return NO;
        }
    }
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (kYunaActivePanel && kYunaActivePanel.superview && !kYunaActivePanel.hidden && kYunaActivePanel.alpha > 0.05) {
        CGPoint p = [touch locationInView:kYunaActivePanel];
        if ([kYunaActivePanel pointInside:p withEvent:nil]) {
            return NO;
        }
    }
    return %orig;
}

%end

%hook UIPasteboard

- (void)setString:(NSString *)string {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureText(string);
}

- (void)setStrings:(NSArray<NSString *> *)strings {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureText(strings.firstObject);
}

- (void)setImage:(UIImage *)image {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureImage(image);
}

- (void)setImages:(NSArray<UIImage *> *)images {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureImage(images.firstObject);
}

- (void)setURL:(NSURL *)url {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureURL(url);
}

- (void)setURLs:(NSArray<NSURL *> *)urls {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureURL(urls.firstObject);
}

- (void)setItems:(NSArray *)items {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_dispatchFromItemsArray(items);
}

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_dispatchFromItemsArray(items);
}

- (void)setValue:(id)value forPasteboardType:(NSString *)pasteboardType {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        yna_captureText((NSString *)value);
    } else if ([value isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)value length] > 0) {
        yna_captureText([(NSAttributedString *)value string]);
    } else if ([value isKindOfClass:[NSURL class]]) {
        yna_captureURL((NSURL *)value);
    } else if ([value isKindOfClass:[UIImage class]]) {
        yna_captureImage((UIImage *)value);
    }
}

- (void)setData:(NSData *)data forPasteboardType:(NSString *)pasteboardType {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    if (!data || data.length == 0 || !pasteboardType) return;

    NSString *lowerType = [pasteboardType lowercaseString];
    if ([lowerType containsString:@"url"]) {
        NSString *urlStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (urlStr && urlStr.length > 0) {
            NSURL *u = [NSURL URLWithString:urlStr];
            if (u && (u.host || u.isFileURL)) {
                yna_captureURL(u);
                return;
            }
        }
    }
    if ([lowerType containsString:@"text"] || [lowerType containsString:@"string"] || [lowerType containsString:@"plain"]) {
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (str && str.length > 0) {
            yna_captureText(str);
        }
    } else if ([lowerType containsString:@"png"] || [lowerType containsString:@"jpeg"] ||
               [lowerType containsString:@"jpg"] || [lowerType containsString:@"tiff"] ||
               [lowerType containsString:@"heic"] || [lowerType containsString:@"image"]) {
        yna_captureImageData(data);
    }
}

- (void)setObjects:(NSArray *)objects {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureFromObjectsArray(objects);
}

- (void)setObjects:(NSArray *)objects options:(NSDictionary *)options {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureFromObjectsArray(objects);
}

- (void)setObjects:(NSArray *)objects localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureFromObjectsArray(objects);
}

- (void)setItemProviders:(NSArray<NSItemProvider *> *)itemProviders {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureFromItemProviders(itemProviders);
}

- (void)setItemProviders:(NSArray<NSItemProvider *> *)itemProviders localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    if (kYunaInPasteboardHook || YunaIsInternalPasteboardWrite() || !yna_isGeneralPasteboard(self)) {
        %orig;
        return;
    }
    kYunaInPasteboardHook = YES;
    @try {
        %orig;
    } @finally {
        kYunaInPasteboardHook = NO;
    }
    yna_captureFromItemProviders(itemProviders);
}

%end

%hook UIKeyboardDockView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        kYunaActiveDockView = self;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            int prefsToken = 0;
            notify_register_dispatch(YUNA_PREFS_NOTIFICATION, &prefsToken, dispatch_get_main_queue(), ^(int t) {
                UIKeyboardDockView *dock = kYunaActiveDockView;
                if (dock) {
                    [dock setNeedsLayout];
                }
            });
        });
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
- (void)yna_layoutDockButton {
    YunaSettingsHelper *settings = [YunaSettingsHelper sharedHelper];
    YunaDockButton *btn = objc_getAssociatedObject(self, &kYunaDockButtonKey);

    if (!btn) {
        btn = [YunaDockButton dockButton];
        btn.delegate = (id<YunaDockButtonDelegate>)self;
        objc_setAssociatedObject(self, &kYunaDockButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:btn];
        [self bringSubviewToFront:btn];
    }

    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    UIView *leftBtn = nil;
    if ([self respondsToSelector:@selector(leftDockItem)]) {
        leftBtn = yna_extractDockItemView([self leftDockItem]);
    }

    UIView *rightBtn = nil;
    if ([self respondsToSelector:@selector(rightDockItem)]) {
        rightBtn = yna_extractDockItemView([self rightDockItem]);
    }

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

    CGFloat targetXCenter = 0.0;
    switch (settings.dockPosition) {
        case YunaDockPositionNextToDictation: {
            if (isRightBtnVisible) {
                targetXCenter = rightBtn.frame.origin.x - (btnW / 2.0) - 6.0;
            } else {
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

    CGRect targetFrame = CGRectMake(targetXCenter - (btnW / 2.0),
                                    targetYCenter - (btnH / 2.0),
                                    btnW,
                                    btnH);
    CGRect cur = btn.frame;
    if (fabs(cur.origin.x - targetFrame.origin.x) > 0.5 ||
        fabs(cur.origin.y - targetFrame.origin.y) > 0.5 ||
        fabs(cur.size.width - targetFrame.size.width) > 0.5 ||
        fabs(cur.size.height - targetFrame.size.height) > 0.5) {
        btn.frame = targetFrame;
    }
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

    YunaPanelView *panel = objc_getAssociatedObject(self, &kYunaPanelViewKey);
    if (panel && panel.superview) {
        [panel dismissAnimated:YES];
        return;
    }

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
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *bundleID = [mainBundle bundleIdentifier];
        if (!bundleID) return;

        BOOL isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
        BOOL isSpotlight = [bundleID isEqualToString:@"com.apple.Spotlight"];

        // Exclude background system daemons (e.g. druid, launchservices, frameworks)
        NSString *execPath = [mainBundle executablePath];
        if (execPath && !isSpringBoard && !isSpotlight) {
            NSArray *excludedPathPrefixes = @[
                @"/usr/libexec/",
                @"/usr/sbin/",
                @"/usr/bin/",
                @"/System/Library/PrivateFrameworks/",
                @"/System/Library/Frameworks/",
                @"/System/Library/CoreServices/"
            ];
            for (NSString *prefix in excludedPathPrefixes) {
                if ([execPath hasPrefix:prefix]) {
                    return;
                }
            }

            // Exclude non-keyboard .appex extensions (widgets, chrono, intents, notification services)
            if ([execPath containsString:@".appex/"]) {
                NSString *extPoint = [mainBundle infoDictionary][@"NSExtension"][@"NSExtensionPointIdentifier"];
                if (extPoint &&
                    ![extPoint isEqualToString:@"com.apple.keyboard-service"] &&
                    ![extPoint hasPrefix:@"com.apple.ui-services"]) {
                    return;
                }
                for (NSString *sub in @[@"Widget", @"Chrono", @"NotificationService", @"Intents"]) {
                    if ([bundleID containsString:sub]) {
                        return;
                    }
                }
            }
        }

        // Exclude non-interactive UIKit helper daemons
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

        if (isSpringBoard) {
            %init(SpringBoardHooks);
        }
        %init(KeyboardHooks);
    }
}
