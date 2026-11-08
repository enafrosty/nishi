#import "YunaStorage.h"
#import "YunaItem.h"
#import "Headers/YunaCommon.h"
#import <CommonCrypto/CommonDigest.h>
#import <notify.h>
#import <sys/stat.h>

@interface YunaStorage () {
    NSMutableArray<YunaItem *> *_items;
    dispatch_queue_t _storageQueue;
}
@end

static void yna_broadcastCommand(uint8_t action, uint64_t hashId) {
    uint64_t state = (((uint64_t)action) << 56) | (hashId & 0x00FFFFFFFFFFFFFFULL);
    int token = 0;
    notify_register_check(YUNA_CMD_NOTIFICATION, &token);
    notify_set_state(token, state);
    notify_post(YUNA_CMD_NOTIFICATION);
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
        _maxItems = 30;
        _storageQueue = dispatch_queue_create("com.frosty.yuna.storage", DISPATCH_QUEUE_SERIAL);
        [self ensureDirectoriesExist];
        [self reloadFromDisk];
    }
    return self;
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
    dispatch_sync(_storageQueue, ^{
        [self _lockedReloadFromDisk];
    });
}

- (void)_lockedReloadFromDisk {
    NSString *filePath = YUNA_HISTORY_FILE;
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:filePath]) {
        _items = [NSMutableArray array];
        return;
    }
    
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:filePath options:0 error:&error];
    if (!data || data.length == 0) {
        _items = [NSMutableArray array];
        return;
    }
    
    NSArray *plistData = [NSPropertyListSerialization propertyListWithData:data
                                                                   options:NSPropertyListImmutable
                                                                    format:NULL
                                                                     error:&error];
    if (!plistData || ![plistData isKindOfClass:[NSArray class]]) {
        _items = [NSMutableArray array];
        return;
    }
    
    NSMutableArray *loaded = [NSMutableArray arrayWithCapacity:plistData.count];
    for (id obj in plistData) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            YunaItem *item = [YunaItem itemFromDictionary:obj];
            if (item) {
                [loaded addObject:item];
            }
        }
    }
    
    // Sort items: pinned first, then newest first
    [loaded sortUsingComparator:^NSComparisonResult(YunaItem *a, YunaItem *b) {
        if (a.isPinned != b.isPinned) {
            return a.isPinned ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.timestamp > b.timestamp) return NSOrderedAscending;
        if (a.timestamp < b.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    
    _items = loaded;
}

- (BOOL)_lockedSaveToDisk {
    [self ensureDirectoriesExist];
    NSString *filePath = YUNA_HISTORY_FILE;
    NSMutableArray *plistArray = [NSMutableArray arrayWithCapacity:_items.count];
    
    for (YunaItem *item in _items) {
        [plistArray addObject:[item dictionaryRepresentation]];
    }
    
    // Clean up any stale containerized CFPreferences key
    CFPreferencesSetAppValue(CFSTR("clipboard_history"), NULL, (CFStringRef)YUNA_BUNDLE_ID);
    CFPreferencesAppSynchronize((CFStringRef)YUNA_BUNDLE_ID);
    
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
        } else {
            YunaLog(@"Failed to write clipboard history to %@: %@", filePath, error);
        }
    }
    
    notify_post(YUNA_CLIPBOARD_NOTIFICATION);
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
    
    // Keep all pinned items. Unpinned items count must not exceed _maxItems.
    NSMutableArray<YunaItem *> *pinned = [NSMutableArray array];
    NSMutableArray<YunaItem *> *unpinned = [NSMutableArray array];
    
    for (YunaItem *item in _items) {
        if (item.isPinned) {
            [pinned addObject:item];
        } else {
            [unpinned addObject:item];
        }
    }
    
    // Sort unpinned items descending by timestamp before truncating
    [unpinned sortUsingComparator:^NSComparisonResult(YunaItem *a, YunaItem *b) {
        if (a.timestamp > b.timestamp) return NSOrderedAscending;
        if (a.timestamp < b.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    
    // Sort pinned items descending by timestamp
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

- (BOOL)addItem:(YunaItem *)newItem {
    if (!newItem) return NO;
    
    __block BOOL added = NO;
    dispatch_sync(_storageQueue, ^{
        [self _lockedReloadFromDisk];
        
        // Check for duplicates
        for (NSUInteger i = 0; i < _items.count; i++) {
            YunaItem *existing = _items[i];
            if (existing.type == newItem.type) {
                if (newItem.type == YunaItemTypeText || newItem.type == YunaItemTypeURL) {
                    if ([existing.text isEqualToString:newItem.text]) {
                        existing.timestamp = [[NSDate date] timeIntervalSince1970];
                        [self _lockedPruneItems];
                        [self _lockedSaveToDisk];
                        added = YES;
                        return;
                    }
                } else if (newItem.type == YunaItemTypeImage) {
                    if (existing.imageRelativePath && newItem.imageRelativePath &&
                        [existing.imageRelativePath isEqualToString:newItem.imageRelativePath]) {
                        // Same image SHA-256 hash copied again
                        existing.timestamp = [[NSDate date] timeIntervalSince1970];
                        [self _lockedPruneItems];
                        [self _lockedSaveToDisk];
                        added = YES;
                        return;
                    }
                } else if (newItem.type == YunaItemTypeFile) {
                    if (existing.fileURLString && newItem.fileURLString &&
                        [existing.fileURLString isEqualToString:newItem.fileURLString]) {
                        existing.timestamp = [[NSDate date] timeIntervalSince1970];
                        [self _lockedPruneItems];
                        [self _lockedSaveToDisk];
                        added = YES;
                        return;
                    }
                }
            }
        }
        
        [_items insertObject:newItem atIndex:0];
        [self _lockedPruneItems];
        [self _lockedSaveToDisk];
        added = YES;
    });
    return added;
}

- (NSArray<YunaItem *> *)allItems {
    __block NSArray *result = nil;
    dispatch_sync(_storageQueue, ^{
        result = [_items copy];
    });
    return result ?: @[];
}

- (NSArray<YunaItem *> *)pinnedItems {
    __block NSMutableArray *result = [NSMutableArray array];
    dispatch_sync(_storageQueue, ^{
        for (YunaItem *item in _items) {
            if (item.isPinned) {
                [result addObject:item];
            }
        }
    });
    return [result copy];
}

- (NSArray<YunaItem *> *)unpinnedItems {
    __block NSMutableArray *result = [NSMutableArray array];
    dispatch_sync(_storageQueue, ^{
        for (YunaItem *item in _items) {
            if (!item.isPinned) {
                [result addObject:item];
            }
        }
    });
    return [result copy];
}

- (NSArray<YunaItem *> *)itemsFilteredByType:(YunaItemType)type {
    __block NSMutableArray *result = [NSMutableArray array];
    dispatch_sync(_storageQueue, ^{
        for (YunaItem *item in _items) {
            if (item.type == type) {
                [result addObject:item];
            }
        }
    });
    return [result copy];
}

- (NSUInteger)totalItemCount {
    __block NSUInteger count = 0;
    dispatch_sync(_storageQueue, ^{
        count = _items.count;
    });
    return count;
}

- (NSUInteger)pinnedItemCount {
    __block NSUInteger count = 0;
    dispatch_sync(_storageQueue, ^{
        for (YunaItem *item in _items) {
            if (item.isPinned) count++;
        }
    });
    return count;
}

- (unsigned long long)totalStorageBytes {
    __block unsigned long long total = 0;
    dispatch_sync(_storageQueue, ^{
        for (YunaItem *item in _items) {
            total += item.itemSize;
        }
    });
    return total;
}

- (void)togglePinnedForUUID:(NSString *)uuid {
    if (!uuid) return;
    dispatch_sync(_storageQueue, ^{
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
            yna_broadcastCommand(YUNA_CMD_TOGGLE_PIN, [YunaItem hashForUUID:uuid]);
        }
    });
}

- (void)togglePinnedForHash:(uint64_t)hashId {
    if (hashId == 0) return;
    dispatch_sync(_storageQueue, ^{
        [self _lockedReloadFromDisk];
        for (YunaItem *item in _items) {
            if ([item hashId] == hashId) {
                item.isPinned = !item.isPinned;
                break;
            }
        }
        [self _lockedPruneItems];
        [self _lockedSaveToDisk];
    });
}

- (void)setPinned:(BOOL)isPinned forUUID:(NSString *)uuid {
    if (!uuid) return;
    dispatch_sync(_storageQueue, ^{
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
            yna_broadcastCommand(YUNA_CMD_TOGGLE_PIN, [YunaItem hashForUUID:uuid]);
        }
    });
}

- (void)deleteItemWithUUID:(NSString *)uuid {
    if (!uuid) return;
    dispatch_sync(_storageQueue, ^{
        [self _lockedReloadFromDisk];
        YunaItem *target = nil;
        for (YunaItem *item in _items) {
            if ([item.uuid isEqualToString:uuid]) {
                target = item;
                break;
            }
        }
        if (target) {
            [self _lockedDeleteAssociatedImageFileForItem:target];
            [_items removeObject:target];
            BOOL saved = [self _lockedSaveToDisk];
            if (!saved) {
                yna_broadcastCommand(YUNA_CMD_DELETE, [YunaItem hashForUUID:uuid]);
            }
        }
    });
}

- (void)deleteItemWithHash:(uint64_t)hashId {
    if (hashId == 0) return;
    dispatch_sync(_storageQueue, ^{
        [self _lockedReloadFromDisk];
        YunaItem *target = nil;
        for (YunaItem *item in _items) {
            if ([item hashId] == hashId) {
                target = item;
                break;
            }
        }
        if (target) {
            [self _lockedDeleteAssociatedImageFileForItem:target];
            [_items removeObject:target];
            [self _lockedSaveToDisk];
        }
    });
}

- (void)clearUnpinnedItems {
    dispatch_sync(_storageQueue, ^{
        [self _lockedReloadFromDisk];
        NSMutableArray *keep = [NSMutableArray array];
        for (YunaItem *item in _items) {
            if (item.isPinned) {
                [keep addObject:item];
            } else {
                [self _lockedDeleteAssociatedImageFileForItem:item];
            }
        }
        _items = keep;
        BOOL saved = [self _lockedSaveToDisk];
        if (!saved) {
            yna_broadcastCommand(YUNA_CMD_CLEAR_UNPINNED, 0);
        }
    });
}

- (void)clearAllItems {
    dispatch_sync(_storageQueue, ^{
        [self _lockedReloadFromDisk];
        for (YunaItem *item in _items) {
            [self _lockedDeleteAssociatedImageFileForItem:item];
        }
        [_items removeAllObjects];
        [self _lockedSaveToDisk];
    });
}

- (nullable NSString *)saveImageData:(NSData *)imageData error:(NSError **)error {
    if (!imageData || imageData.length == 0) return nil;
    
    [self ensureDirectoriesExist];
    
    // Hash data for unique filename
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
