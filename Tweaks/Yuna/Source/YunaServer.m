#import "YunaServer.h"
#import "YunaStorage.h"
#import "YunaItem.h"
#import "UI/YunaSettingsHelper.h"
#import "Headers/YunaCommon.h"
#import <notify.h>

@interface YunaServer () {
    NSInteger _lastChangeCount;
    dispatch_queue_t _workerQueue;
    BOOL _isObserving;
    int _tokenPasteboard;
    int _tokenUIKit;
    int _tokenExt;
    NSTimer *_pollTimer;
}
@end

@implementation YunaServer

+ (instancetype)sharedServer {
    static YunaServer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[YunaServer alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastChangeCount = -1;
        _workerQueue = dispatch_queue_create("com.frosty.yuna.server", DISPATCH_QUEUE_SERIAL);
        _isObserving = NO;
        _tokenPasteboard = 0;
        _tokenUIKit = 0;
        _tokenExt = 0;
    }
    return self;
}

- (void)startServer {
    if (_isObserving) return;
    _isObserving = YES;
    
    YunaLog(@"Starting Yuna clipboard server in SpringBoard...");
    
    // Initial change count on main thread
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    _lastChangeCount = pasteboard.changeCount;
    
    // 1. In-process pasteboard changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pasteboardChanged:)
                                                 name:UIPasteboardChangedNotification
                                               object:nil];
    
    // 2. System Darwin pasteboard notifications
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch("com.apple.Pasteboard.pasteboardChanged", &_tokenPasteboard, dispatch_get_main_queue(), ^(int token) {
        [weakSelf checkPasteboardOnMainThread];
    });
    
    notify_register_dispatch("com.apple.uikit.pasteboardchanged", &_tokenUIKit, dispatch_get_main_queue(), ^(int token) {
        [weakSelf checkPasteboardOnMainThread];
    });
    
    notify_register_dispatch(YUNA_EXT_PASTEBOARD_NOTIFICATION, &_tokenExt, dispatch_get_main_queue(), ^(int token) {
        [weakSelf checkPasteboardOnMainThread];
    });
    
    // 3. Periodic fallback timer while SpringBoard is active (every 2.5s)
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                  target:self
                                                selector:@selector(checkPasteboardOnMainThread)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stopServer {
    if (!_isObserving) return;
    _isObserving = NO;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIPasteboardChangedNotification
                                                  object:nil];
    if (_tokenPasteboard > 0) notify_cancel(_tokenPasteboard);
    if (_tokenUIKit > 0) notify_cancel(_tokenUIKit);
    if (_tokenExt > 0) notify_cancel(_tokenExt);
    
    [_pollTimer invalidate];
    _pollTimer = nil;
}

- (void)pasteboardChanged:(NSNotification *)note {
    [self checkPasteboardOnMainThread];
}

- (void)checkPasteboardOnMainThread {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self checkPasteboardOnMainThread];
        });
        return;
    }
    
    YunaSettingsHelper *settings = [YunaSettingsHelper sharedHelper];
    if (!settings.enabled) return;
    
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSInteger currentChangeCount = pasteboard.changeCount;
    if (currentChangeCount == _lastChangeCount) {
        return;
    }
    _lastChangeCount = currentChangeCount;
    
    // Read pasteboard on main thread to prevent UIKit Main Thread Checker aborts
    BOOL hasImages = settings.saveImages && (pasteboard.hasImages || [pasteboard containsPasteboardTypes:@[@"public.png", @"public.jpeg", @"public.tiff"]]);
    UIImage *image = hasImages ? pasteboard.image : nil;
    
    BOOL hasURLs = settings.saveFiles && (pasteboard.hasURLs || pasteboard.URL != nil);
    NSURL *url = hasURLs ? pasteboard.URL : nil;
    
    BOOL hasStrings = pasteboard.hasStrings || pasteboard.string.length > 0;
    NSString *string = hasStrings ? [pasteboard.string copy] : nil;
    
    // Dispatch CPU & disk-intensive operations to background worker queue
    dispatch_async(_workerQueue, ^{
        @autoreleasepool {
            [self processPayloadWithImage:image url:url string:string settings:settings];
        }
    });
}

- (void)processPayloadWithImage:(nullable UIImage *)image
                            url:(nullable NSURL *)url
                         string:(nullable NSString *)string
                       settings:(YunaSettingsHelper *)settings {
    // 1. Process Image
    if (image) {
        CGSize size = image.size;
        CGFloat maxDim = 1200.0;
        if (size.width > maxDim || size.height > maxDim) {
            CGFloat scale = (size.width > size.height) ? (maxDim / size.width) : (maxDim / size.height);
            CGSize targetSize = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
            UIGraphicsBeginImageContextWithOptions(targetSize, NO, 1.0);
            [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
            image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        
        NSData *data = UIImageJPEGRepresentation(image, 0.85);
        if (!data) {
            data = UIImagePNGRepresentation(image);
        }
        
        if (data && data.length > 0) {
            NSError *error = nil;
            NSString *fileName = [[YunaStorage sharedInstance] saveImageData:data error:&error];
            if (fileName) {
                YunaItem *item = [YunaItem itemWithImageRelativePath:fileName size:data.length];
                [[YunaStorage sharedInstance] addItem:item];
                YunaLog(@"Saved copied image (%lu bytes): %@", (unsigned long)data.length, fileName);
                return;
            }
        }
    }
    
    // 2. Process URL or File
    if (url) {
        if ([url isFileURL]) {
            NSNumber *fileSize = nil;
            [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            YunaItem *item = [YunaItem itemWithFileURL:url size:[fileSize unsignedIntegerValue]];
            [[YunaStorage sharedInstance] addItem:item];
            YunaLog(@"Saved copied file URL: %@", [url path]);
            return;
        } else {
            YunaItem *item = [YunaItem itemWithURL:url];
            [[YunaStorage sharedInstance] addItem:item];
            YunaLog(@"Saved copied web URL: %@", [url absoluteString]);
            return;
        }
    }
    
    // 3. Process Text String
    if (string && [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) {
        if ([string hasPrefix:@"http://"] || [string hasPrefix:@"https://"]) {
            NSURL *candidateURL = [NSURL URLWithString:string];
            if (candidateURL && candidateURL.host) {
                YunaItem *item = [YunaItem itemWithURL:candidateURL];
                [[YunaStorage sharedInstance] addItem:item];
                YunaLog(@"Saved URL string: %@", string);
                return;
            }
        }
        
        YunaItem *item = [YunaItem itemWithText:string];
        [[YunaStorage sharedInstance] addItem:item];
        YunaLog(@"Saved text string (%lu chars)", (unsigned long)string.length);
        return;
    }
}

@end
