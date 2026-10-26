#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YunaServer : NSObject

+ (instancetype)sharedServer;
- (void)startServer;
- (void)stopServer;

@end

NS_ASSUME_NONNULL_END
