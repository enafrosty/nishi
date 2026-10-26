#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Headers/YunaCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface YunaItem : NSObject

@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, assign) YunaItemType type;
@property (nonatomic, copy, nullable) NSString *text;
@property (nonatomic, copy, nullable) NSString *imageRelativePath;
@property (nonatomic, copy, nullable) NSString *imageBase64;
@property (nonatomic, copy, nullable) NSString *fileURLString;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, assign) NSTimeInterval timestamp;
@property (nonatomic, assign) BOOL isPinned;
@property (nonatomic, assign) NSUInteger itemSize;

+ (instancetype)itemWithText:(NSString *)text;
+ (instancetype)itemWithImage:(UIImage *)image;
+ (instancetype)itemWithImageRelativePath:(NSString *)relPath size:(NSUInteger)size;
+ (instancetype)itemWithURL:(NSURL *)url;
+ (instancetype)itemWithFileURL:(NSURL *)fileURL size:(NSUInteger)size;

- (NSDictionary<NSString *, id> *)dictionaryRepresentation;
+ (nullable instancetype)itemFromDictionary:(NSDictionary<NSString *, id> *)dict;

- (NSString *)displayTitle;
- (NSString *)displaySubtitle;
- (NSString *)relativeTimeString;
- (nullable UIImage *)loadImage;

@end

NS_ASSUME_NONNULL_END
