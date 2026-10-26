#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol YunaDockButtonDelegate <NSObject>
- (void)yunaDockButtonDidTap:(UIButton *)button;
@end

@interface YunaDockButton : UIButton

@property (nonatomic, weak, nullable) id<YunaDockButtonDelegate> delegate;

+ (instancetype)dockButton;
- (void)updateAppearanceForTraitCollection:(UITraitCollection *)traitCollection;

@end

NS_ASSUME_NONNULL_END
