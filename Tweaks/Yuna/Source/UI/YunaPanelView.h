#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol YunaPanelViewDelegate <NSObject>
- (void)yunaPanelViewDidRequestDismiss:(UIView *)panelView;
@end

@interface YunaPanelView : UIView

@property (nonatomic, weak, nullable) id<YunaPanelViewDelegate> delegate;

+ (instancetype)panelViewWithFrame:(CGRect)frame;
- (void)reloadData;
- (void)presentInView:(UIView *)containerView;
- (void)dismissAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
