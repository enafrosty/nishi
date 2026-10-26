#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "YunaItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface YunaStorage : NSObject

@property (nonatomic, assign) NSInteger maxItems;

+ (instancetype)sharedInstance;

- (void)reloadFromDisk;

- (NSArray<YunaItem *> *)allItems;
- (NSArray<YunaItem *> *)pinnedItems;
- (NSArray<YunaItem *> *)unpinnedItems;
- (NSArray<YunaItem *> *)itemsFilteredByType:(YunaItemType)type;

- (NSUInteger)totalItemCount;
- (NSUInteger)pinnedItemCount;
- (unsigned long long)totalStorageBytes;

- (BOOL)addItem:(YunaItem *)item;
- (void)togglePinnedForUUID:(NSString *)uuid;
- (void)setPinned:(BOOL)isPinned forUUID:(NSString *)uuid;
- (void)deleteItemWithUUID:(NSString *)uuid;
- (void)clearUnpinnedItems;
- (void)clearAllItems;

- (nullable NSString *)saveImageData:(NSData *)imageData error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
