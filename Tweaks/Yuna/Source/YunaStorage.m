#import "YunaStorage.h"
#import "YunaItem.h"
#import "Headers/YunaCommon.h"
#import <CommonCrypto/CommonDigest.h>
#import <notify.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <stdatomic.h>

static atomic_bool kYunaInternalPasteboardWrite = ATOMIC_VAR_INIT(false);
static char kYunaStorageQueueKey;

void YunaSetInternalPasteboardWrite(BOOL flag) {
    atomic_store(&kYunaInternalPasteboardWrite, flag ? true : false);
}

BOOL YunaIsInternalPasteboardWrite(void) {
    return atomic_load(&kYunaInternalPasteboardWrite) ? YES : NO;
}

@interface YunaStorage () {
    NSMutableArray<YunaItem *> *_items;
    NSMutableArray<YunaItem *> *_unsyncedLocalItems;
    dispatch_queue_t _storageQueue;
    dispatch_queue_t _ipcQueue;
    BOOL _hasLastSavedMtime;
    struct timespec _lastSavedMtime;
    int _cmdNotifyToken;
    int _ipcSlotTokens[YUNA_IPC_SLOT_COUNT];
    BOOL _ipcSlotsRegistered;
}
@end

static BOOL yna_itemsHaveSameContent(YunaItem *a, YunaItem *b) {
    if (!a || !b || a.type != b.type) return NO;
    switch (a.type) {
        case YunaItemTypeText:
        case YunaItemTypeURL:
            return (a.text && b.text && [a.text isEqualToString:b.text]);
        case YunaItemTypeImage:
            if (a.imageRelativePath && b.imageRelativePath &&
                [a.imageRelativePath isEqualToString:b.imageRelativePath]) {
                return YES;
            }
            if (a.imageBase64 && b.imageBase64 &&
                [a.imageBase64 isEqualToString:b.imageBase64]) {
                return YES;
            }
            return NO;
        case YunaItemTypeFile:
            return (a.fileURLString && b.fileURLString && [a.fileURLString isEqualToString:b.fileURLString]);
    }
    return NO;
}

static size_t yna_utf8TruncatedLength(const uint8_t *bytes, size_t totalLen, size_t maxBytes) {
    if (totalLen <= maxBytes) return totalLen;
    size_t cut = maxBytes;
    // Back up past UTF-8 continuation bytes (10xxxxxx) so we never split a codepoint
    while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
        cut--;
    }
    return cut;
}

@implementation YunaStorage

+ (instancetype)sharedInstance {
    static YunaStorage *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[YunaStorage alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [NSMutableArray array];
        _unsyncedLocalItems = [NSMutableArray array];
        _maxItems = 30;
        _hasLastSavedMtime = NO;
        memset(&_lastSavedMtime, 0, sizeof(_lastSavedMtime));
        _cmdNotifyToken = 0;
        _ipcSlotsRegistered = NO;
        for (int i = 0; i < YUNA_IPC_SLOT_COUNT; i++) {
            _ipcSlotTokens[i] = 0;
        }

        _storageQueue = dispatch_queue_create("com.frosty.yuna.storage", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_storageQueue, &kYunaStorageQueueKey, &kYunaStorageQueueKey, NULL);
        _ipcQueue = dispatch_queue_create("com.frosty.yuna.ipc.sender", DISPATCH_QUEUE_SERIAL);

        // One-time migration cleanup of stale containerized CFPreferences key
        CFPreferencesSetAppValue(CFSTR("clipboard_history"), NULL, (CFStringRef)YUNA_BUNDLE_ID);
        CFPreferencesAppSynchronize((CFStringRef)YUNA_BUNDLE_ID);

        [self ensureDirectoriesExist];
        [self reloadFromDisk];
    }
    return self;
}

- (void)_performSync:(dispatch_block_t)block {
    if (!block) return;
    if (dispatch_get_specific(&kYunaStorageQueueKey) == &kYunaStorageQueueKey) {
        block();
    } else {
        dispatch_sync(_storageQueue, block);
    }
}

- (void)ensureDirectoriesExist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *baseDir = YUNA_STORAGE_PATH;
    NSString *imgDir = YUNA_IMAGES_DIR;

    NSDictionary *dirAttrs = @{NSFilePosixPermissions: @(0777)};

    if (![fm fileExistsAtPath:baseDir]) {
        [fm createDirectoryAtPath:baseDir withIntermediateDirectories:YES attributes:dirAttrs error:nil];
    } else {
        [fm setAttributes:dirAttrs ofItemAtPath:baseDir error:nil];
    }

    if (![fm fileExistsAtPath:imgDir]) {
        [fm createDirectoryAtPath:imgDir withIntermediateDirectories:YES attributes:dirAttrs error:nil];
    } else {
        [fm setAttributes:dirAttrs ofItemAtPath:imgDir error:nil];
    }

    chmod([baseDir fileSystemRepresentation], 0777);
    chmod([imgDir fileSystemRepresentation], 0777);

    NSString *filePath = YUNA_HISTORY_FILE;
    if ([fm fileExistsAtPath:filePath]) {
        chmod([filePath fileSystemRepresentation], 0666);
    }
}

- (void)reloadFromDisk {
    [self _performSync:^{
        [self _lockedReloadFromDisk];
    }];
}

- (void)reloadFromDiskIfModifiedExternally {
    [self _performSync:^{
        struct stat st;
        if (_hasLastSavedMtime && stat([YUNA_HISTORY_FILE fileSystemRepresentation], &st) == 0) {
            if (st.st_mtimespec.tv_sec == _lastSavedMtime.tv_sec &&
                st.st_mtimespec.tv_nsec == _lastSavedMtime.tv_nsec) {
                return;
            }
        }
        [self _lockedReloadFromDisk];
    }];
}

- (void)_lockedSortArray:(NSMutableArray<YunaItem *> *)array {
    [array sortUsingComparator:^NSComparisonResult(YunaItem *a, YunaItem *b) {
        if (a.isPinned != b.isPinned) {
            return a.isPinned ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.timestamp > b.timestamp) return NSOrderedAscending;
        if (a.timestamp < b.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (void)_lockedReloadFromDisk {
    NSString *filePath = YUNA_HISTORY_FILE;
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<YunaItem *> *loaded = [NSMutableArray array];
    BOOL readSucceeded = NO;

    if ([fm fileExistsAtPath:filePath]) {
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:filePath options:0 error:&error];
        if (data && data.length > 0) {
            NSArray *plistData = [NSPropertyListSerialization propertyListWithData:data
                                                                           options:NSPropertyListImmutable
                                                                            format:NULL
                                                                             error:&error];
            if (plistData && [plistData isKindOfClass:[NSArray class]]) {
                readSucceeded = YES;
                for (id obj in plistData) {
                    if ([obj isKindOfClass:[NSDictionary class]]) {
                        YunaItem *item = [YunaItem itemFromDictionary:obj];
                        if (item) {
                            [loaded addObject:item];
                        }
                    }
                }
            }
        }
    }

    if (!readSucceeded && _items.count > 0) {
        // Keep current in-memory items if disk file does not exist yet or could not be read
        loaded = [_items mutableCopy];
    }

    // Merge any unsynced in-memory items captured in this sandboxed process so they are never lost
    if (_unsyncedLocalItems.count > 0) {
        NSMutableArray<YunaItem *> *stillUnsynced = [NSMutableArray array];
        for (YunaItem *localItem in _unsyncedLocalItems) {
            NSUInteger matchIdx = NSNotFound;
            for (NSUInteger i = 0; i < loaded.count; i++) {
                YunaItem *diskItem = loaded[i];
                if ([diskItem.uuid isEqualToString:localItem.uuid] || yna_itemsHaveSameContent(diskItem, localItem)) {
                    matchIdx = i;
                    break;
                }
            }

            if (matchIdx != NSNotFound) {
                YunaItem *diskItem = loaded[matchIdx];
                if (diskItem.timestamp >= localItem.timestamp - 0.5) {
                    // Already persisted on disk
                    continue;
                }
                // Local copy is newer than disk entry; keep local timestamp/pin state in view
                loaded[matchIdx] = localItem;
                [stillUnsynced addObject:localItem];
            } else {
                [loaded addObject:localItem];
                [stillUnsynced addObject:localItem];
            }
        }
        _unsyncedLocalItems = stillUnsynced;
    }

    [self _lockedSortArray:loaded];
    _items = loaded;
}

- (BOOL)_lockedSaveToDisk {
    NSString *filePath = YUNA_HISTORY_FILE;
    NSMutableArray *plistArray = [NSMutableArray arrayWithCapacity:_items.count];

    for (YunaItem *item in _items) {
        [plistArray addObject:[item dictionaryRepresentation]];
    }

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plistArray
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    BOOL written = NO;
    if (data) {
        written = [data writeToFile:filePath options:NSDataWritingAtomic error:&error];
        if (!written) {
            written = [data writeToFile:filePath options:0 error:&error];
        }
        if (written) {
            chmod([filePath fileSystemRepresentation], 0666);
            struct stat st;
            if (stat([filePath fileSystemRepresentation], &st) == 0) {
                _lastSavedMtime = st.st_mtimespec;
                _hasLastSavedMtime = YES;
            }
        }
    }

    if (written) {
        notify_post(YUNA_CLIPBOARD_NOTIFICATION);
    }
    return written;
}

- (void)_lockedDeleteAssociatedImageFileForItem:(YunaItem *)item {
    if (item.type == YunaItemTypeImage && item.imageRelativePath.length > 0) {
        NSString *fullPath = [YUNA_IMAGES_DIR stringByAppendingPathComponent:item.imageRelativePath];
        [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
    }
}

- (void)_lockedPruneItems {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:YUNA_PREFS_FILE];
    if (prefs && prefs[@"maxItems"]) {
        NSInteger settingsMax = [prefs[@"maxItems"] integerValue];
        if (settingsMax >= 5 && settingsMax <= 200) {
            _maxItems = settingsMax;
        }
    }

    NSMutableArray<YunaItem *> *pinned = [NSMutableArray array];
    NSMutableArray<YunaItem *> *unpinned = [NSMutableArray array];

    for (YunaItem *item in _items) {
        if (item.isPinned) {
            [pinned addObject:item];
        } else {
            [unpinned addObject:item];
        }
    }

    [unpinned sortUsingComparator:^NSComparisonResult(YunaItem *a, YunaItem *b) {
        if (a.timestamp > b.timestamp) return NSOrderedAscending;
        if (a.timestamp < b.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    [pinned sortUsingComparator:^NSComparisonResult(YunaItem *a, YunaItem *b) {
        if (a.timestamp > b.timestamp) return NSOrderedAscending;
        if (a.timestamp < b.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    if (unpinned.count > (NSUInteger)_maxItems) {
        NSRange deleteRange = NSMakeRange(_maxItems, unpinned.count - _maxItems);
        NSArray<YunaItem *> *toRemove = [unpinned subarrayWithRange:deleteRange];
        for (YunaItem *item in toRemove) {
            [self _lockedDeleteAssociatedImageFileForItem:item];
        }
        [unpinned removeObjectsInRange:deleteRange];
    }

    NSMutableArray<YunaItem *> *combined = [NSMutableArray arrayWithCapacity:pinned.count + unpinned.count];
    [combined addObjectsFromArray:pinned];
    [combined addObjectsFromArray:unpinned];
    _items = combined;
}

- (void)_lockedTrackUnsyncedItem:(YunaItem *)item {
    if (!item) return;
    for (NSUInteger i = 0; i < _unsyncedLocalItems.count; i++) {
        YunaItem *existing = _unsyncedLocalItems[i];
        if ([existing.uuid isEqualToString:item.uuid] || yna_itemsHaveSameContent(existing, item)) {
            _unsyncedLocalItems[i] = item;
            return;
        }
    }
    [_unsyncedLocalItems insertObject:item atIndex:0];
    if (_unsyncedLocalItems.count > 30) {
        [_unsyncedLocalItems removeLastObject];
    }
}

- (void)_lockedRemoveFromUnsyncedUUID:(NSString *)uuid {
    if (!uuid) return;
    NSMutableIndexSet *toDelete = [NSMutableIndexSet indexSet];
    [_unsyncedLocalItems enumerateObjectsUsingBlock:^(YunaItem *obj, NSUInteger idx, BOOL *stop) {
        if ([obj.uuid isEqualToString:uuid]) {
            [toDelete addIndex:idx];
        }
    }];
    if (toDelete.count > 0) {
        [_unsyncedLocalItems removeObjectsAtIndexes:toDelete];
    }
}

- (void)dispatchBroadcastCommand:(uint8_t)action hashId:(uint64_t)hashId {
    uint64_t state = (((uint64_t)action) << 56) | (hashId & 0x00FFFFFFFFFFFFFFULL);
    dispatch_async(_ipcQueue, ^{
        if (self->_cmdNotifyToken <= 0) {
            notify_register_check(YUNA_CMD_NOTIFICATION, &self->_cmdNotifyToken);
        }
        if (self->_cmdNotifyToken > 0) {
            notify_set_state(self->_cmdNotifyToken, state);
            notify_post(YUNA_CMD_NOTIFICATION);
        }
    });
}

- (void)sendItemToSpringBoardIPC:(YunaItem *)item {
    if (!item) return;
    NSDictionary *dict = [item dictionaryRepresentation];
    if (!dict) return;

    YunaItemType itemType = item.type;
    NSString *fallbackText = [item.text copy];

    dispatch_async(_ipcQueue, ^{
        @autoreleasepool {
            BOOL sentViaTCP = NO;
            NSError *err = nil;
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                      format:NSPropertyListBinaryFormat_v1_0
                                                                     options:0
                                                                       error:&err];
            if (data && data.length > 0) {
                sentViaTCP = [self _sendPayloadViaLoopbackTCP:data];
            }

            if (!sentViaTCP && (itemType == YunaItemTypeText || itemType == YunaItemTypeURL) && fallbackText.length > 0) {
                [self _sendTextViaDarwinSlotRing:fallbackText itemType:itemType];
            }
        }
    });
}

- (BOOL)_sendPayloadViaLoopbackTCP:(NSData *)data {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int yes = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    struct timeval ioTimeout;
    ioTimeout.tv_sec = 0;
    ioTimeout.tv_usec = 300000;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));

    int origFlags = fcntl(fd, F_GETFL, 0);
    if (origFlags >= 0) {
        fcntl(fd, F_SETFL, origFlags | O_NONBLOCK);
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(YUNA_IPC_TCP_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc < 0) {
        if (errno != EINPROGRESS) {
            close(fd);
            return NO;
        }
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);
        struct timeval connTimeout;
        connTimeout.tv_sec = 0;
        connTimeout.tv_usec = 300000;
        if (select(fd + 1, NULL, &wfds, NULL, &connTimeout) <= 0) {
            close(fd);
            return NO;
        }
        int soErr = 0;
        socklen_t soLen = sizeof(soErr);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen) != 0 || soErr != 0) {
            close(fd);
            return NO;
        }
    }

    if (origFlags >= 0) {
        fcntl(fd, F_SETFL, origFlags & ~O_NONBLOCK);
    }

    uint32_t netLen = htonl((uint32_t)data.length);
    uint8_t lenBuf[4];
    memcpy(lenBuf, &netLen, 4);

    // Combine header and payload for single write where possible
    size_t totalLen = 4 + data.length;
    uint8_t stackBuf[512];
    NSMutableData *heapBuf = nil;
    const uint8_t *sendPtr = NULL;

    if (totalLen <= sizeof(stackBuf)) {
        memcpy(stackBuf, lenBuf, 4);
        memcpy(stackBuf + 4, data.bytes, data.length);
        sendPtr = stackBuf;
    } else {
        heapBuf = [NSMutableData dataWithCapacity:totalLen];
        [heapBuf appendBytes:lenBuf length:4];
        [heapBuf appendData:data];
        sendPtr = (const uint8_t *)heapBuf.bytes;
    }

    size_t sent = 0;
    while (sent < totalLen) {
        ssize_t n = send(fd, sendPtr + sent, totalLen - sent, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            close(fd);
            return NO;
        }
        sent += (size_t)n;
    }

    close(fd);
    return YES;
}

- (void)_sendTextViaDarwinSlotRing:(NSString *)text itemType:(YunaItemType)itemType {
    if (!_ipcSlotsRegistered) {
        for (int i = 0; i < YUNA_IPC_SLOT_COUNT; i++) {
            NSString *name = [NSString stringWithFormat:@"com.frosty.yuna/ipc.%d", i];
            notify_register_check([name UTF8String], &_ipcSlotTokens[i]);
        }
        _ipcSlotsRegistered = YES;
    }

    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8 || utf8.length == 0) return;

    size_t maxBytes = (YUNA_IPC_SLOT_COUNT - 1) * 8;
    size_t byteLen = yna_utf8TruncatedLength((const uint8_t *)utf8.bytes, utf8.length, maxBytes);
    if (byteLen == 0) return;

    const uint8_t *bytes = (const uint8_t *)utf8.bytes;
    uint32_t slotCount = (uint32_t)((byteLen + 7) / 8);

    for (uint32_t i = 0; i < slotCount && (i + 1) < YUNA_IPC_SLOT_COUNT; i++) {
        uint64_t val = 0;
        for (int b = 0; b < 8; b++) {
            size_t offset = (size_t)i * 8 + (size_t)b;
            if (offset < byteLen) {
                val |= ((uint64_t)bytes[offset]) << (b * 8);
            }
        }
        if (_ipcSlotTokens[i + 1] > 0) {
            notify_set_state(_ipcSlotTokens[i + 1], val);
        }
    }

    uint64_t header = ((uint64_t)(uint32_t)byteLen) | (((uint64_t)(uint32_t)itemType) << 32);
    if (_ipcSlotTokens[0] > 0) {
        notify_set_state(_ipcSlotTokens[0], header);
    }
    notify_post(YUNA_EXT_PASTEBOARD_NOTIFICATION);
}

- (BOOL)addItem:(YunaItem *)newItem {
    if (!newItem) return NO;

    __block BOOL added = NO;
    __block YunaItem *ipcItemToSend = nil;

    [self _performSync:^{
        [self _lockedReloadFromDisk];

        for (NSUInteger i = 0; i < _items.count; i++) {
            YunaItem *existing = _items[i];
            if (yna_itemsHaveSameContent(existing, newItem)) {
                existing.timestamp = [[NSDate date] timeIntervalSince1970];
                [self _lockedPruneItems];
                BOOL saved = [self _lockedSaveToDisk];
                if (!saved) {
                    [self _lockedTrackUnsyncedItem:existing];
                    ipcItemToSend = existing;
                }
                added = YES;
                return;
            }
        }

        [_items insertObject:newItem atIndex:0];
        [self _lockedPruneItems];
        BOOL saved = [self _lockedSaveToDisk];
        if (!saved) {
            [self _lockedTrackUnsyncedItem:newItem];
            ipcItemToSend = newItem;
        }
        added = YES;
    }];

    if (ipcItemToSend) {
        [self sendItemToSpringBoardIPC:ipcItemToSend];
    }

    return added;
}

- (NSArray<YunaItem *> *)allItems {
    __block NSArray *result = nil;
    [self _performSync:^{
        result = [_items copy];
    }];
    return result ?: @[];
}

- (NSArray<YunaItem *> *)pinnedItems {
    __block NSMutableArray *result = [NSMutableArray array];
    [self _performSync:^{
        for (YunaItem *item in _items) {
            if (item.isPinned) {
                [result addObject:item];
            }
        }
    }];
    return [result copy];
}

- (NSArray<YunaItem *> *)unpinnedItems {
    __block NSMutableArray *result = [NSMutableArray array];
    [self _performSync:^{
        for (YunaItem *item in _items) {
            if (!item.isPinned) {
                [result addObject:item];
            }
        }
    }];
    return [result copy];
}

- (NSArray<YunaItem *> *)itemsFilteredByType:(YunaItemType)type {
    __block NSMutableArray *result = [NSMutableArray array];
    [self _performSync:^{
        for (YunaItem *item in _items) {
            if (item.type == type) {
                [result addObject:item];
            }
        }
    }];
    return [result copy];
}

- (NSUInteger)totalItemCount {
    __block NSUInteger count = 0;
    [self _performSync:^{
        count = _items.count;
    }];
    return count;
}

- (NSUInteger)pinnedItemCount {
    __block NSUInteger count = 0;
    [self _performSync:^{
        for (YunaItem *item in _items) {
            if (item.isPinned) count++;
        }
    }];
    return count;
}

- (unsigned long long)totalStorageBytes {
    __block unsigned long long total = 0;
    [self _performSync:^{
        for (YunaItem *item in _items) {
            total += item.itemSize;
        }
    }];
    return total;
}

- (void)togglePinnedForUUID:(NSString *)uuid {
    if (!uuid) return;
    __block BOOL needsBroadcast = NO;
    [self _performSync:^{
        [self _lockedReloadFromDisk];
        for (YunaItem *item in _items) {
            if ([item.uuid isEqualToString:uuid]) {
                item.isPinned = !item.isPinned;
                break;
            }
        }
        [self _lockedPruneItems];
        BOOL saved = [self _lockedSaveToDisk];
        if (!saved) {
            needsBroadcast = YES;
        }
    }];
    if (needsBroadcast) {
        [self dispatchBroadcastCommand:YUNA_CMD_TOGGLE_PIN hashId:[YunaItem hashForUUID:uuid]];
    }
}

- (void)togglePinnedForHash:(uint64_t)hashId {
    if (hashId == 0) return;
    [self _performSync:^{
        [self _lockedReloadFromDisk];
        for (YunaItem *item in _items) {
            if ([item hashId] == hashId) {
                item.isPinned = !item.isPinned;
                break;
            }
        }
        [self _lockedPruneItems];
        [self _lockedSaveToDisk];
    }];
}

- (void)setPinned:(BOOL)isPinned forUUID:(NSString *)uuid {
    if (!uuid) return;
    __block BOOL needsBroadcast = NO;
    [self _performSync:^{
        [self _lockedReloadFromDisk];
        for (YunaItem *item in _items) {
            if ([item.uuid isEqualToString:uuid]) {
                item.isPinned = isPinned;
                break;
            }
        }
        [self _lockedPruneItems];
        BOOL saved = [self _lockedSaveToDisk];
        if (!saved) {
            needsBroadcast = YES;
        }
    }];
    if (needsBroadcast) {
        [self dispatchBroadcastCommand:YUNA_CMD_TOGGLE_PIN hashId:[YunaItem hashForUUID:uuid]];
    }
}

- (void)deleteItemWithUUID:(NSString *)uuid {
    if (!uuid) return;
    __block BOOL needsBroadcast = NO;
    [self _performSync:^{
        [self _lockedReloadFromDisk];
        YunaItem *target = nil;
        for (YunaItem *item in _items) {
            if ([item.uuid isEqualToString:uuid]) {
                target = item;
                break;
            }
        }
        [self _lockedRemoveFromUnsyncedUUID:uuid];
        if (target) {
            [self _lockedDeleteAssociatedImageFileForItem:target];
            [_items removeObject:target];
            BOOL saved = [self _lockedSaveToDisk];
            if (!saved) {
                needsBroadcast = YES;
            }
        }
    }];
    if (needsBroadcast) {
        [self dispatchBroadcastCommand:YUNA_CMD_DELETE hashId:[YunaItem hashForUUID:uuid]];
    }
}

- (void)deleteItemWithHash:(uint64_t)hashId {
    if (hashId == 0) return;
    [self _performSync:^{
        [self _lockedReloadFromDisk];
        YunaItem *target = nil;
        for (YunaItem *item in _items) {
            if ([item hashId] == hashId) {
                target = item;
                break;
            }
        }
        if (target) {
            [self _lockedRemoveFromUnsyncedUUID:target.uuid];
            [self _lockedDeleteAssociatedImageFileForItem:target];
            [_items removeObject:target];
            [self _lockedSaveToDisk];
        }
    }];
}

- (void)clearUnpinnedItems {
    __block BOOL needsBroadcast = NO;
    [self _performSync:^{
        [self _lockedReloadFromDisk];
        NSMutableArray *keep = [NSMutableArray array];
        for (YunaItem *item in _items) {
            if (item.isPinned) {
                [keep addObject:item];
            } else {
                [self _lockedDeleteAssociatedImageFileForItem:item];
            }
        }
        NSMutableArray *unsyncedKeep = [NSMutableArray array];
        for (YunaItem *item in _unsyncedLocalItems) {
            if (item.isPinned) {
                [unsyncedKeep addObject:item];
            }
        }
        _unsyncedLocalItems = unsyncedKeep;
        _items = keep;
        BOOL saved = [self _lockedSaveToDisk];
        if (!saved) {
            needsBroadcast = YES;
        }
    }];
    if (needsBroadcast) {
        [self dispatchBroadcastCommand:YUNA_CMD_CLEAR_UNPINNED hashId:0];
    }
}

- (void)clearAllItems {
    [self _performSync:^{
        [self _lockedReloadFromDisk];
        for (YunaItem *item in _items) {
            [self _lockedDeleteAssociatedImageFileForItem:item];
        }
        [_unsyncedLocalItems removeAllObjects];
        [_items removeAllObjects];
        [self _lockedSaveToDisk];
    }];
}

- (nullable NSString *)saveImageData:(NSData *)imageData error:(NSError **)error {
    if (!imageData || imageData.length == 0) return nil;

    [self ensureDirectoriesExist];

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(imageData.bytes, (CC_LONG)imageData.length, hash);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }

    NSString *fileName = [NSString stringWithFormat:@"%@.png", [hex substringToIndex:16]];
    NSString *fullPath = [YUNA_IMAGES_DIR stringByAppendingPathComponent:fileName];

    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        BOOL written = [imageData writeToFile:fullPath options:NSDataWritingAtomic error:nil];
        if (!written) {
            written = [imageData writeToFile:fullPath options:0 error:nil];
        }
        if (written) {
            chmod([fullPath fileSystemRepresentation], 0666);
        }
    }

    return fileName;
}

@end
