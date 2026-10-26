#import <UIKit/UIKit.h>
#import "../YunaItem.h"

NS_ASSUME_NONNULL_BEGIN

@protocol YunaItemCellDelegate <NSObject>
- (void)yunaItemCellDidRequestPinToggle:(YunaItem *)item;
- (void)yunaItemCellDidRequestDelete:(YunaItem *)item;
@end

@interface YunaItemCell : UICollectionViewCell

@property (nonatomic, strong, readonly) YunaItem *item;
@property (nonatomic, weak, nullable) id<YunaItemCellDelegate> delegate;

- (void)configureWithItem:(YunaItem *)item;

@end

NS_ASSUME_NONNULL_END
