#import "YunaPanelView.h"
#import "YunaItemCell.h"
#import "YunaStorage.h"
#import "YunaSettingsHelper.h"
#import "../Headers/UIKeyboardPrivate.h"
#import "../Headers/YunaCommon.h"
#import <notify.h>

typedef NS_ENUM(NSInteger, YunaFilterTab) {
    YunaFilterTabAll = 0,
    YunaFilterTabPinned = 1,
    YunaFilterTabText = 2,
    YunaFilterTabMedia = 3
};

@interface YunaPanelView () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, YunaItemCellDelegate> {
    int _clipboardNotifyToken;
    int _prefsNotifyToken;
}

@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *headerBar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UILabel *emptyStateLabel;

@property (nonatomic, strong) NSArray<YunaItem *> *displayItems;
@property (nonatomic, assign) YunaFilterTab currentFilter;

@end

@implementation YunaPanelView

+ (instancetype)panelViewWithFrame:(CGRect)frame {
    return [[YunaPanelView alloc] initWithFrame:frame];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _currentFilter = YunaFilterTabAll;
        [self setupUI];
        [self registerNotifications];
        [self reloadData];
    }
    return self;
}

- (void)dealloc {
    notify_cancel(_clipboardNotifyToken);
    notify_cancel(_prefsNotifyToken);
}

- (void)setupUI {
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor clearColor];
    
    // Blur Background
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    _blurView.frame = self.bounds;
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blurView];
    
    // Header Bar
    _headerBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 44.0)];
    _headerBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _headerBar.backgroundColor = [UIColor clearColor];
    [self addSubview:_headerBar];
    
    // Title
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 10.0, 60.0, 24.0)];
    _titleLabel.text = @"Yuna";
    _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    _titleLabel.textColor = [UIColor labelColor];
    [_headerBar addSubview:_titleLabel];
    
    // Filter Segmented Control
    NSArray *segments = @[@"All", @"Pinned", @"Text", @"Media"];
    _filterControl = [[UISegmentedControl alloc] initWithItems:segments];
    _filterControl.selectedSegmentIndex = 0;
    _filterControl.frame = CGRectMake(76.0, 7.0, self.bounds.size.width - 156.0, 30.0);
    _filterControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_filterControl addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    [_headerBar addSubview:_filterControl];
    
    // Clear Unpinned Button
    _clearButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _clearButton.frame = CGRectMake(self.bounds.size.width - 76.0, 7.0, 30.0, 30.0);
    _clearButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightRegular];
    [_clearButton setImage:[UIImage systemImageNamed:@"trash" withConfiguration:config] forState:UIControlStateNormal];
    _clearButton.tintColor = [UIColor systemRedColor];
    [_clearButton addTarget:self action:@selector(clearUnpinnedTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_headerBar addSubview:_clearButton];
    
    // Close Button
    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.frame = CGRectMake(self.bounds.size.width - 38.0, 7.0, 30.0, 30.0);
    _closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:config] forState:UIControlStateNormal];
    _closeButton.tintColor = [UIColor secondaryLabelColor];
    [_closeButton addTarget:self action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_headerBar addSubview:_closeButton];
    
    // Collection View with Horizontal Scroll Layout
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumInteritemSpacing = 8.0;
    layout.minimumLineSpacing = 8.0;
    layout.sectionInset = UIEdgeInsetsMake(6.0, 10.0, 6.0, 10.0);
    
    CGFloat cvY = 44.0;
    CGFloat cvHeight = self.bounds.size.height - cvY;
    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectMake(0, cvY, self.bounds.size.width, cvHeight) collectionViewLayout:layout];
    _collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _collectionView.backgroundColor = [UIColor clearColor];
    _collectionView.showsHorizontalScrollIndicator = NO;
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    [_collectionView registerClass:[YunaItemCell class] forCellWithReuseIdentifier:@"YunaItemCell"];
    [self addSubview:_collectionView];
    
    // Long-press gesture for context actions
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.4;
    [_collectionView addGestureRecognizer:lp];
    
    // Empty state label
    _emptyStateLabel = [[UILabel alloc] initWithFrame:_collectionView.bounds];
    _emptyStateLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    _emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    _emptyStateLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    _emptyStateLabel.text = @"No clipboard items found";
    _emptyStateLabel.hidden = YES;
    [_collectionView addSubview:_emptyStateLabel];
}

- (void)registerNotifications {
    notify_register_dispatch(YUNA_CLIPBOARD_NOTIFICATION, &_clipboardNotifyToken, dispatch_get_main_queue(), ^(int token) {
        [[YunaStorage sharedInstance] reloadFromDisk];
        [self reloadData];
    });
    
    notify_register_dispatch(YUNA_PREFS_NOTIFICATION, &_prefsNotifyToken, dispatch_get_main_queue(), ^(int token) {
        [self.collectionView.collectionViewLayout invalidateLayout];
        [self.collectionView reloadData];
    });
}

- (void)filterChanged:(UISegmentedControl *)sender {
    [[YunaSettingsHelper sharedHelper] triggerHapticFeedback];
    _currentFilter = (YunaFilterTab)sender.selectedSegmentIndex;
    [self reloadData];
}

- (void)reloadData {
    YunaStorage *storage = [YunaStorage sharedInstance];
    switch (_currentFilter) {
        case YunaFilterTabAll:
            _displayItems = [storage allItems];
            break;
        case YunaFilterTabPinned:
            _displayItems = [storage pinnedItems];
            break;
        case YunaFilterTabText:
            _displayItems = [storage itemsFilteredByType:YunaItemTypeText];
            break;
        case YunaFilterTabMedia: {
            NSArray *images = [storage itemsFilteredByType:YunaItemTypeImage];
            NSArray *files = [storage itemsFilteredByType:YunaItemTypeFile];
            NSArray *urls = [storage itemsFilteredByType:YunaItemTypeURL];
            NSMutableArray *combined = [NSMutableArray arrayWithArray:images];
            [combined addObjectsFromArray:files];
            [combined addObjectsFromArray:urls];
            _displayItems = [combined copy];
            break;
        }
    }
    
    _emptyStateLabel.hidden = (_displayItems.count > 0);
    [self.collectionView reloadData];
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return _displayItems.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    YunaItemCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"YunaItemCell" forIndexPath:indexPath];
    if (indexPath.item >= 0 && (NSUInteger)indexPath.item < _displayItems.count) {
        YunaItem *item = _displayItems[indexPath.item];
        [cell configureWithItem:item];
        cell.delegate = self;
    }
    return cell;
}

#pragma mark - UICollectionViewDelegateFlowLayout (Row Management)

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    // Row management: determine height based on configured rows
    NSInteger rows = [[YunaSettingsHelper sharedHelper] numberOfRows];
    if (rows < 1) rows = 1;
    if (rows > 4) rows = 4;
    
    UICollectionViewFlowLayout *flow = (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat totalSpacing = flow.sectionInset.top + flow.sectionInset.bottom + (flow.minimumInteritemSpacing * (rows - 1));
    CGFloat availableHeight = collectionView.bounds.size.height - totalSpacing;
    if (availableHeight < 40.0) availableHeight = 40.0;
    
    CGFloat itemHeight = floor(availableHeight / rows);
    
    // Width can adapt based on screen or fixed comfortable width
    CGFloat itemWidth = 210.0;
    if (rows == 1) {
        itemWidth = 250.0;
    }
    
    return CGSizeMake(itemWidth, itemHeight);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.item < 0 || (NSUInteger)indexPath.item >= _displayItems.count) return;
    YunaItem *item = _displayItems[indexPath.item];
    
    [[YunaSettingsHelper sharedHelper] triggerHapticFeedback];
    [self pasteItem:item];
    
    if ([[YunaSettingsHelper sharedHelper] autoDismissOnPaste]) {
        [self dismissAnimated:YES];
    }
}

#pragma mark - Paste Action

- (void)pasteItem:(YunaItem *)item {
    if (item.type == YunaItemTypeText || item.type == YunaItemTypeURL) {
        NSString *textToInsert = item.text ?: @"";
        
        // Attempt direct insertion via UIKeyboardImpl (runtime resolution to avoid private linker symbols)
        Class kbClass = NSClassFromString(@"UIKeyboardImpl");
        id kb = nil;
        if (kbClass && [kbClass respondsToSelector:@selector(activeInstance)]) {
            kb = [kbClass performSelector:@selector(activeInstance)];
        }
        if (kb && [kb respondsToSelector:@selector(insertText:)]) {
            [kb performSelector:@selector(insertText:) withObject:textToInsert];
            return;
        }
        
        // Fallback to pasteboard
        [[UIPasteboard generalPasteboard] setString:textToInsert];
    } else if (item.type == YunaItemTypeImage) {
        UIImage *img = [item loadImage];
        if (img) {
            [[UIPasteboard generalPasteboard] setImage:img];
        }
    } else if (item.type == YunaItemTypeFile) {
        if (item.fileURLString) {
            NSURL *url = [NSURL URLWithString:item.fileURLString];
            if (url) {
                [[UIPasteboard generalPasteboard] setURL:url];
            }
        }
    }
}

#pragma mark - YunaItemCellDelegate

- (void)yunaItemCellDidRequestPinToggle:(YunaItem *)item {
    [[YunaStorage sharedInstance] togglePinnedForUUID:item.uuid];
    [self reloadData];
}

- (void)yunaItemCellDidRequestDelete:(YunaItem *)item {
    [[YunaStorage sharedInstance] deleteItemWithUUID:item.uuid];
    [self reloadData];
}

#pragma mark - Long Press Context Menu

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    
    CGPoint point = [gesture locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (!indexPath || indexPath.item < 0 || (NSUInteger)indexPath.item >= _displayItems.count) return;
    
    YunaItem *item = _displayItems[indexPath.item];
    [[YunaSettingsHelper sharedHelper] triggerHapticFeedback];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[item displayTitle]
                                                                   message:[item displaySubtitle]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSString *pinTitle = item.isPinned ? @"Unpin Item" : @"Pin to Top";
    [alert addAction:[UIAlertAction actionWithTitle:pinTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[YunaStorage sharedInstance] togglePinnedForUUID:item.uuid];
        [self reloadData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy to Clipboard" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self pasteItem:item];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YunaStorage sharedInstance] deleteItemWithUUID:item.uuid];
        [self reloadData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    UIViewController *topVC = [self topViewController];
    if (topVC) {
        alert.popoverPresentationController.sourceView = self.collectionView;
        alert.popoverPresentationController.sourceRect = CGRectMake(point.x, point.y, 1.0, 1.0);
        [topVC presentViewController:alert animated:YES completion:nil];
    }
}

- (UIViewController *)topViewController {
    UIWindow *window = self.window ?: [UIApplication sharedApplication].keyWindow;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

#pragma mark - Header Actions

- (void)clearUnpinnedTapped:(UIButton *)sender {
    [[YunaSettingsHelper sharedHelper] triggerHapticFeedback];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear History"
                                                                   message:@"Do you want to clear all unpinned items? Pinned items will be preserved."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YunaStorage sharedInstance] clearUnpinnedItems];
        [self reloadData];
    }]];
    
    UIViewController *topVC = [self topViewController];
    if (topVC) {
        [topVC presentViewController:alert animated:YES completion:nil];
    }
}

- (void)closeTapped:(UIButton *)sender {
    [[YunaSettingsHelper sharedHelper] triggerHapticFeedback];
    [self dismissAnimated:YES];
}

#pragma mark - Presentation / Dismissal

- (void)presentInView:(UIView *)containerView {
    if (!containerView) return;
    
    CGRect targetFrame = self.frame;
    if (targetFrame.size.height <= 0 || targetFrame.size.width <= 0) {
        targetFrame = CGRectMake(0, 0, containerView.bounds.size.width, 220.0);
    }
    
    self.alpha = 1.0;
    self.frame = CGRectMake(0, containerView.bounds.size.height, targetFrame.size.width, targetFrame.size.height);
    [containerView addSubview:self];
    
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.2 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.frame = targetFrame;
    } completion:nil];
}

- (void)dismissAnimated:(BOOL)animated {
    if (!animated) {
        [self removeFromSuperview];
        if ([self.delegate respondsToSelector:@selector(yunaPanelViewDidRequestDismiss:)]) {
            [self.delegate yunaPanelViewDidRequestDismiss:self];
        }
        return;
    }
    
    CGFloat offscreenY = self.superview ? self.superview.bounds.size.height : (self.frame.origin.y + self.frame.size.height + 50.0);
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.frame = CGRectMake(0, offscreenY, self.bounds.size.width, self.bounds.size.height);
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        if ([self.delegate respondsToSelector:@selector(yunaPanelViewDidRequestDismiss:)]) {
            [self.delegate yunaPanelViewDidRequestDismiss:self];
        }
    }];
}

@end
