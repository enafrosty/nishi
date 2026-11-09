#import "YunaServer.h"
#import "YunaStorage.h"
#import "YunaItem.h"
#import "UI/YunaSettingsHelper.h"
#import "Headers/YunaCommon.h"
#import <notify.h>

@interface YunaServer () {
    dispatch_queue_t _workerQueue;
    BOOL _isObserving;
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
        _workerQueue = dispatch_queue_create("com.frosty.yuna.server", DISPATCH_QUEUE_SERIAL);
        _isObserving = NO;
        _tokenExt = 0;
        _tokenCmd = 0;
        _tokenClipboard = 0;
    }
    return self;
}

- (void)startServer {
    if (_isObserving) return;
    _isObserving = YES;
    
    YunaLog(@"Starting Yuna IPC clipboard server in SpringBoard (zero general pasteboard eavesdropping)...");
    
    __weak typeof(self) weakSelf = self;
    
    // 1. IPC Clipboard Capture: receives serialized YunaItem directly from in-app copy hooks
    notify_register_dispatch(YUNA_EXT_PASTEBOARD_NOTIFICATION, &_tokenExt, _workerQueue, ^(int token) {
        [weakSelf handleIncomingIPCItem];
    });
    
    // 2. Sandboxed IPC Command Dispatch: executes mutations (pin, delete, clear) on behalf of sandboxed apps
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
    
    // 3. Reload in-memory items when any other unsandboxed process mutates history.plist
    notify_register_dispatch(YUNA_CLIPBOARD_NOTIFICATION, &_tokenClipboard, _workerQueue, ^(int t) {
        [[YunaStorage sharedInstance] reloadFromDisk];
    });
}

- (void)stopServer {
    if (!_isObserving) return;
    _isObserving = NO;
    
    if (_tokenExt > 0) notify_cancel(_tokenExt);
    if (_tokenCmd > 0) notify_cancel(_tokenCmd);
    if (_tokenClipboard > 0) notify_cancel(_tokenClipboard);
}

- (void)handleIncomingIPCItem {
    @autoreleasepool {
        UIPasteboard *ipcPB = [UIPasteboard pasteboardWithName:YUNA_IPC_PASTEBOARD_NAME create:YES];
        if (!ipcPB) return;
        
        NSData *data = [ipcPB dataForPasteboardType:YUNA_IPC_ITEM_TYPE];
        if (!data || data.length == 0) return;
        
        // Clear data to prevent re-consumption
        [ipcPB setData:[NSData data] forPasteboardType:YUNA_IPC_ITEM_TYPE];
        
        NSError *error = nil;
        NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data
                                                                       options:NSPropertyListImmutable
                                                                        format:NULL
                                                                         error:&error];
        if (!dict || ![dict isKindOfClass:[NSDictionary class]]) return;
        
        YunaItem *item = [YunaItem itemFromDictionary:dict];
        if (!item) return;
        
        [[YunaStorage sharedInstance] addItem:item];
        YunaLog(@"SpringBoard successfully persisted IPC item: %@", [item displayTitle]);
    }
}

@end
