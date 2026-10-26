#import "YunaItemCell.h"
#import "YunaSettingsHelper.h"

@interface YunaItemCell ()

@property (nonatomic, strong) UIView *cardBackground;
@property (nonatomic, strong) UIImageView *typeImageView;
@property (nonatomic, strong) UIImageView *thumbnailImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *pinButton;
@property (nonatomic, strong, readwrite) YunaItem *item;

@end

@implementation YunaItemCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    self.contentView.clipsToBounds = YES;
    
    _cardBackground = [[UIView alloc] initWithFrame:self.contentView.bounds];
    _cardBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _cardBackground.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _cardBackground.layer.cornerRadius = 10.0;
    _cardBackground.layer.borderWidth = 1.0;
    _cardBackground.layer.borderColor = [UIColor separatorColor].CGColor;
    _cardBackground.clipsToBounds = YES;
    [self.contentView addSubview:_cardBackground];
    
    _typeImageView = [[UIImageView alloc] init];
    _typeImageView.contentMode = UIViewContentModeScaleAspectFit;
    _typeImageView.tintColor = [UIColor systemBlueColor];
    [_cardBackground addSubview:_typeImageView];
    
    _thumbnailImageView = [[UIImageView alloc] init];
    _thumbnailImageView.contentMode = UIViewContentModeScaleAspectFill;
    _thumbnailImageView.clipsToBounds = YES;
    _thumbnailImageView.layer.cornerRadius = 6.0;
    _thumbnailImageView.hidden = YES;
    [_cardBackground addSubview:_thumbnailImageView];
    
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_cardBackground addSubview:_titleLabel];
    
    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.numberOfLines = 1;
    [_cardBackground addSubview:_subtitleLabel];
    
    _pinButton = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightMedium];
    [_pinButton setImage:[UIImage systemImageNamed:@"pin" withConfiguration:config] forState:UIControlStateNormal];
    [_pinButton setImage:[UIImage systemImageNamed:@"pin.fill" withConfiguration:config] forState:UIControlStateSelected];
    _pinButton.tintColor = [UIColor systemOrangeColor];
    [_pinButton addTarget:self action:@selector(handlePinTap:) forControlEvents:UIControlEventTouchUpInside];
    [_cardBackground addSubview:_pinButton];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _item = nil;
    _thumbnailImageView.image = nil;
    _thumbnailImageView.hidden = YES;
    _typeImageView.image = nil;
    _typeImageView.hidden = YES;
    _titleLabel.text = nil;
    _subtitleLabel.text = nil;
    _subtitleLabel.hidden = NO;
    _pinButton.selected = NO;
    _cardBackground.transform = CGAffineTransformIdentity;
    _cardBackground.alpha = 1.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    CGRect bounds = self.contentView.bounds;
    _cardBackground.frame = bounds;
    
    CGFloat padding = 8.0;
    CGFloat pinSize = 22.0;
    _pinButton.frame = CGRectMake(bounds.size.width - pinSize - padding, (bounds.size.height - pinSize) / 2.0, pinSize, pinSize);
    
    CGFloat leftOffset = padding;
    CGFloat rightLimit = _pinButton.frame.origin.x - 4.0;
    
    if (self.item.type == YunaItemTypeImage) {
        CGFloat thumbSize = bounds.size.height - (padding * 2.0);
        if (thumbSize < 24.0) thumbSize = 24.0;
        _thumbnailImageView.frame = CGRectMake(leftOffset, padding, thumbSize, thumbSize);
        _thumbnailImageView.hidden = NO;
        _typeImageView.hidden = YES;
        leftOffset += thumbSize + 8.0;
    } else {
        CGFloat iconSize = 20.0;
        _typeImageView.frame = CGRectMake(leftOffset, (bounds.size.height - iconSize) / 2.0, iconSize, iconSize);
        _typeImageView.hidden = NO;
        _thumbnailImageView.hidden = YES;
        leftOffset += iconSize + 8.0;
    }
    
    CGFloat labelWidth = rightLimit - leftOffset;
    if (labelWidth < 20.0) labelWidth = 20.0;
    
    CGFloat labelHeight = 16.0;
    if (bounds.size.height < 42.0) {
        // Compact row mode (e.g. 4 rows)
        _subtitleLabel.hidden = YES;
        _titleLabel.frame = CGRectMake(leftOffset, (bounds.size.height - labelHeight) / 2.0, labelWidth, labelHeight);
    } else {
        _subtitleLabel.hidden = NO;
        CGFloat totalTextHeight = labelHeight + 14.0;
        CGFloat textStartY = (bounds.size.height - totalTextHeight) / 2.0;
        _titleLabel.frame = CGRectMake(leftOffset, textStartY, labelWidth, labelHeight);
        _subtitleLabel.frame = CGRectMake(leftOffset, textStartY + labelHeight, labelWidth, 14.0);
    }
}

- (void)configureWithItem:(YunaItem *)item {
    _item = item;
    
    _titleLabel.text = [item displayTitle];
    _subtitleLabel.text = [item displaySubtitle];
    _pinButton.selected = item.isPinned;
    
    // Style for pinned items
    if (item.isPinned) {
        _cardBackground.layer.borderColor = [UIColor systemOrangeColor].CGColor;
        _cardBackground.layer.borderWidth = 1.5;
        _pinButton.alpha = 1.0;
    } else {
        _cardBackground.layer.borderColor = [UIColor separatorColor].CGColor;
        _cardBackground.layer.borderWidth = 1.0;
        _pinButton.alpha = 0.45;
    }
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightRegular];
    switch (item.type) {
        case YunaItemTypeText:
            _typeImageView.image = [UIImage systemImageNamed:@"text.bubble" withConfiguration:config];
            _typeImageView.tintColor = [UIColor systemBlueColor];
            break;
        case YunaItemTypeImage:
            _thumbnailImageView.image = [item loadImage];
            break;
        case YunaItemTypeURL:
            _typeImageView.image = [UIImage systemImageNamed:@"link" withConfiguration:config];
            _typeImageView.tintColor = [UIColor systemIndigoColor];
            break;
        case YunaItemTypeFile:
            _typeImageView.image = [UIImage systemImageNamed:@"doc" withConfiguration:config];
            _typeImageView.tintColor = [UIColor systemTealColor];
            break;
    }
    
    [self setNeedsLayout];
}

- (void)handlePinTap:(UIButton *)sender {
    [[YunaSettingsHelper sharedHelper] triggerHapticFeedback];
    if ([self.delegate respondsToSelector:@selector(yunaItemCellDidRequestPinToggle:)]) {
        [self.delegate yunaItemCellDidRequestPinToggle:self.item];
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.15 animations:^{
        self.cardBackground.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97) : CGAffineTransformIdentity;
        self.cardBackground.alpha = highlighted ? 0.8 : 1.0;
    }];
}

@end
