#import "YunaStorage.h"
#import <CommonCrypto/CommonDigest.h>
#import <notify.h>

@interface YunaStorage () {
    NSMutableArray<YunaItem *> *_items;
    dispatch_queue_t _storageQueue;
}
@end

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
    
    if (![fm fileExistsAtPath:baseDir]) {
        [fm createDirectoryAtPath:baseDir withIntermediateDirectories:YES attributes:@{
            NSFilePosixPermissions: @(0755)
        } error:nil];
    }
    if (![fm fileExistsAtPath:imgDir]) {
        [fm createDirectoryAtPath:imgDir withIntermediateDirectories:YES attributes:@{
            NSFilePosixPermissions: @(0755)
        } error:nil];
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
    
    NSArray *plistData = [NSArray arrayWithContentsOfFile:filePath];
    if (![plistData isKindOfClass:[NSArray class]]) {
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

- (void)_lockedSaveToDisk {
    [self ensureDirectoriesExist];
    NSString *filePath = YUNA_HISTORY_FILE;
    NSMutableArray *plistArray = [NSMutableArray arrayWithCapacity:_items.count];
    
    for (YunaItem *item in _items) {
        [plistArray addObject:[item dictionaryRepresentation]];
    }
    
    BOOL success = [plistArray writeToFile:filePath atomically:YES];
    if (!success) {
        YunaLog(@"Failed to write clipboard history to %@", filePath);
    } else {
        notify_post(YUNA_CLIPBOARD_NOTIFICATION);
    }
}

- (void)_lockedDeleteAssociatedImageFileForItem:(YunaItem *)item {
    if (item.type == YunaItemTypeImage && item.imageRelativePath.length > 0) {
        NSString *fullPath = [YUNA_IMAGES_DIR stringByAppendingPathComponent:item.imageRelativePath];
        [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
    }
}

- (void)_lockedPruneItems {
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
        for (YunaItem *item in _items) {
            if ([item.uuid isEqualToString:uuid]) {
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
        for (YunaItem *item in _items) {
            if ([item.uuid isEqualToString:uuid]) {
                item.isPinned = isPinned;
                break;
            }
        }
        [self _lockedPruneItems];
        [self _lockedSaveToDisk];
    });
}

- (void)deleteItemWithUUID:(NSString *)uuid {
    if (!uuid) return;
    dispatch_sync(_storageQueue, ^{
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
            [self _lockedSaveToDisk];
        }
    });
}

- (void)clearUnpinnedItems {
    dispatch_sync(_storageQueue, ^{
        NSMutableArray *keep = [NSMutableArray array];
        for (YunaItem *item in _items) {
            if (item.isPinned) {
                [keep addObject:item];
            } else {
                [self _lockedDeleteAssociatedImageFileForItem:item];
            }
        }
        _items = keep;
        [self _lockedSaveToDisk];
    });
}

- (void)clearAllItems {
    dispatch_sync(_storageQueue, ^{
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
        BOOL written = [imageData writeToFile:fullPath options:NSDataWritingAtomic error:error];
        if (!written) {
            return nil;
        }
    }
    
    return fileName;
}

@end
