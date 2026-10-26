#import "YunaDockButton.h"
#import "YunaSettingsHelper.h"

@implementation YunaDockButton

+ (instancetype)dockButton {
    YunaDockButton *button = [YunaDockButton buttonWithType:UIButtonTypeCustom];
    [button setupButton];
    return button;
}

- (void)setupButton {
    self.frame = CGRectMake(0, 0, 44.0, 44.0);
    self.contentMode = UIViewContentModeCenter;
    self.adjustsImageWhenHighlighted = YES;
    self.accessibilityLabel = @"Yuna Clipboard";
    self.accessibilityHint = @"Opens saved clipboard history";
    
    // SF Symbol for clipboard on iOS 15/16
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightRegular];
    UIImage *symbolImage = [UIImage systemImageNamed:@"doc.on.clipboard" withConfiguration:config];
    if (!symbolImage) {
        symbolImage = [UIImage systemImageNamed:@"list.bullet.clipboard" withConfiguration:config];
    }
    if (!symbolImage) {
        symbolImage = [UIImage systemImageNamed:@"doc.text" withConfiguration:config];
    }
    
    [self setImage:symbolImage forState:UIControlStateNormal];
    [self updateColors];
    
    [self addTarget:self action:@selector(handleTap:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)updateColors {
    UIColor *tint = [UIColor labelColor];
    self.tintColor = tint;
}

- (void)updateAppearanceForTraitCollection:(UITraitCollection *)traitCollection {
    [self updateColors];
}

- (void)handleTap:(UIButton *)sender {
    [[YunaSettingsHelper sharedHelper] triggerHapticFeedback];
    if ([self.delegate respondsToSelector:@selector(yunaDockButtonDidTap:)]) {
        [self.delegate yunaDockButtonDidTap:self];
    }
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(44.0, 44.0);
}

@end
