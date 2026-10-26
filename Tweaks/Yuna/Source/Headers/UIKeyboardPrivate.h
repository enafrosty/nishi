#ifndef UIKEYBOARD_PRIVATE_H
#define UIKEYBOARD_PRIVATE_H

#import <UIKit/UIKit.h>

@interface UIKeyboardDockItemButton : UIButton
@end

@interface UIKeyboardDockItem : NSObject
@property (nonatomic, retain) UIKeyboardDockItemButton *button;
@property (nonatomic, retain) NSString *identifier;
@property (nonatomic, assign) BOOL enabled;
@end

@interface UIKeyboardDockView : UIView
@property (nonatomic, retain) UIKeyboardDockItem *leftDockItem;
@property (nonatomic, retain) UIKeyboardDockItem *rightDockItem;
@property (nonatomic, retain) UIKeyboardDockItem *centerDockItem;
- (id)_dockItemWithButton:(id)arg1;
- (void)layoutSubviews;
@end

@interface UIKeyboardImpl : UIView
+ (instancetype)activeInstance;
+ (instancetype)sharedInstance;
- (void)insertText:(NSString *)text;
- (void)deleteBackward;
- (id)inputDelegate;
- (UIResponder *)delegate;
- (BOOL)isInHardwareKeyboardMode;
@end

@interface UIKeyboardLayoutStar : UIView
@end

@interface UIInputWindowController : UIViewController
+ (instancetype)sharedInstance;
@end

@interface SpringBoard : UIApplication
@end

#endif /* UIKEYBOARD_PRIVATE_H */
