#import "YNARootListController.h"
#import "../../Source/YunaStorage.h"
#import "../../Source/Headers/YunaCommon.h"
#import <spawn.h>

extern char **environ;

@implementation YNARootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)clearUnpinnedHistory:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Unpinned Items"
                                                                   message:@"Are you sure you want to remove all unpinned clipboard items? Pinned snippets will be preserved."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YunaStorage sharedInstance] clearUnpinnedItems];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearAllHistory:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Entire History"
                                                                   message:@"Are you sure you want to delete all items, including pinned items and cached images? This cannot be undone."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YunaStorage sharedInstance] clearAllItems];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)respring:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring SpringBoard"
                                                                   message:@"Would you like to respring now to ensure all changes take effect?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        pid_t pid;
        const char *argv[] = {"sbreload", NULL};
        int status = posix_spawn(&pid, "/var/jb/usr/bin/sbreload", NULL, NULL, (char *const *)argv, environ);
        if (status != 0) {
            const char *argv2[] = {"killall", "-9", "SpringBoard", NULL};
            posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)argv2, environ);
        }
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

@end
