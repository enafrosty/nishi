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
    int _tokenCmd;
    int _tokenClipboard;
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
        _tokenCmd = 0;
        _tokenClipboard = 0;
    }
    return self;
}

- (void)startServer {
    if (_isObserving) return;
    _isObserving = YES;
    
    YunaLog(@"Starting Yuna clipboard server in SpringBoard (event-driven, zero polling)...");
    
    // 1. In-process pasteboard changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pasteboardChanged:)
                                                 name:UIPasteboardChangedNotification
                                               object:nil];
    
    // 2. System Darwin pasteboard notifications on background queue (zero impact on SpringBoard main thread)
    __weak typeof(self) weakSelf = self;
    dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    notify_register_dispatch("com.apple.Pasteboard.pasteboardChanged", &_tokenPasteboard, bgQueue, ^(int token) {
        [weakSelf checkPasteboard];
    });
    
    notify_register_dispatch("com.apple.uikit.pasteboardchanged", &_tokenUIKit, bgQueue, ^(int token) {
        [weakSelf checkPasteboard];
    });
    
    notify_register_dispatch(YUNA_EXT_PASTEBOARD_NOTIFICATION, &_tokenExt, bgQueue, ^(int token) {
        [weakSelf checkPasteboard];
    });
    
    // 3. Sandboxed IPC command dispatch: executes mutations (pin, delete, clear) on behalf of sandboxed apps
    notify_register_dispatch(YUNA_CMD_NOTIFICATION, &_tokenCmd, _workerQueue, ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        if (state == 0) return;
        uint8_t action = (state >> 56) & 0xFF;
        uint64_t hashId = state & 0x00FFFFFFFFFFFFFFULL;
        
        if (action == YUNA_CMD_TOGGLE_PIN) {
            [[YunaStorage sharedInstance] togglePinnedForHash:hashId];
        } else if (action == YUNA_CMD_DELETE) {
            [[YunaStorage sharedInstance] deleteItemWithHash:hashId];
        } else if (action == YUNA_CMD_CLEAR_UNPINNED) {
            [[YunaStorage sharedInstance] clearUnpinnedItems];
        }
    });
    
    // 4. Reload in-memory items when any other process mutates history.plist
    notify_register_dispatch(YUNA_CLIPBOARD_NOTIFICATION, &_tokenClipboard, _workerQueue, ^(int t) {
        [[YunaStorage sharedInstance] reloadFromDisk];
    });
    
    // Initial sync of existing clipboard
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf checkPasteboard];
    });
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
    if (_tokenCmd > 0) notify_cancel(_tokenCmd);
    if (_tokenClipboard > 0) notify_cancel(_tokenClipboard);
}

- (void)pasteboardChanged:(NSNotification *)note {
    [self checkPasteboard];
}

- (void)checkPasteboard {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self checkPasteboard];
        });
        return;
    }
    
    YunaSettingsHelper *settings = [YunaSettingsHelper sharedHelper];
    if (!settings.enabled) return;
    
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    if (!pasteboard) return;
    
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
        YunaItem *item = [YunaItem itemWithImage:image];
        if (item) {
            [[YunaStorage sharedInstance] addItem:item];
            YunaLog(@"Saved copied image (%lu bytes)", (unsigned long)item.itemSize);
            return;
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
