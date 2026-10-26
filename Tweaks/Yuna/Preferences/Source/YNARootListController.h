#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface YNARootListController : PSListController

- (void)clearUnpinnedHistory:(PSSpecifier *)specifier;
- (void)clearAllHistory:(PSSpecifier *)specifier;
- (void)respring:(PSSpecifier *)specifier;

@end
