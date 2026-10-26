#import "YunaItem.h"
#import "YunaStorage.h"

@implementation YunaItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _uuid = [[NSUUID UUID] UUIDString];
        _timestamp = [[NSDate date] timeIntervalSince1970];
        _isPinned = NO;
        _type = YunaItemTypeText;
        _itemSize = 0;
    }
    return self;
}

+ (instancetype)itemWithText:(NSString *)text {
    YunaItem *item = [[YunaItem alloc] init];
    item.type = YunaItemTypeText;
    item.text = text ?: @"";
    item.title = [self truncatedPreviewForString:text maxChars:40];
    item.itemSize = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return item;
}

+ (instancetype)itemWithImage:(UIImage *)image {
    if (!image) return nil;
    
    CGSize size = image.size;
    CGFloat maxDim = 320.0;
    UIImage *thumb = image;
    if (size.width > maxDim || size.height > maxDim) {
        CGFloat scale = (size.width > size.height) ? (maxDim / size.width) : (maxDim / size.height);
        CGSize targetSize = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
        UIGraphicsBeginImageContextWithOptions(targetSize, NO, 1.0);
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
        thumb = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    
    NSData *thumbData = UIImageJPEGRepresentation(thumb, 0.7);
    NSString *b64 = [thumbData base64EncodedStringWithOptions:0];
    
    NSData *fullData = UIImageJPEGRepresentation(image, 0.85);
    if (!fullData) fullData = thumbData;
    
    NSError *err = nil;
    NSString *fileName = [[YunaStorage sharedInstance] saveImageData:fullData error:&err];
    
    YunaItem *item = [[YunaItem alloc] init];
    item.type = YunaItemTypeImage;
    item.imageRelativePath = fileName;
    item.imageBase64 = b64;
    item.title = @"Image";
    item.itemSize = fullData.length;
    return item;
}

+ (instancetype)itemWithImageRelativePath:(NSString *)relPath size:(NSUInteger)size {
    YunaItem *item = [[YunaItem alloc] init];
    item.type = YunaItemTypeImage;
    item.imageRelativePath = relPath;
    item.title = @"Image";
    item.itemSize = size;
    return item;
}

+ (instancetype)itemWithURL:(NSURL *)url {
    YunaItem *item = [[YunaItem alloc] init];
    item.type = YunaItemTypeURL;
    item.text = [url absoluteString];
    item.title = [url host] ?: [url absoluteString];
    item.itemSize = [[url absoluteString] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return item;
}

+ (instancetype)itemWithFileURL:(NSURL *)fileURL size:(NSUInteger)size {
    YunaItem *item = [[YunaItem alloc] init];
    item.type = YunaItemTypeFile;
    item.fileURLString = [fileURL absoluteString];
    item.title = [fileURL lastPathComponent] ?: @"File";
    item.itemSize = size;
    return item;
}

+ (NSString *)truncatedPreviewForString:(NSString *)string maxChars:(NSUInteger)maxChars {
    if (!string) return @"";
    NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Replace newlines with spaces for single-line title preview
    NSString *singleLine = [trimmed stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([singleLine rangeOfString:@"  "].location != NSNotFound) {
        singleLine = [singleLine stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (singleLine.length <= maxChars) {
        return singleLine;
    }
    return [NSString stringWithFormat:@"%@...", [singleLine substringToIndex:maxChars]];
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"uuid"] = self.uuid ?: @"";
    dict[@"type"] = @(self.type);
    dict[@"timestamp"] = @(self.timestamp);
    dict[@"isPinned"] = @(self.isPinned);
    dict[@"itemSize"] = @(self.itemSize);
    
    if (self.text) dict[@"text"] = self.text;
    if (self.imageRelativePath) dict[@"imageRelativePath"] = self.imageRelativePath;
    if (self.imageBase64) dict[@"imageBase64"] = self.imageBase64;
    if (self.fileURLString) dict[@"fileURLString"] = self.fileURLString;
    if (self.title) dict[@"title"] = self.title;
    
    return [dict copy];
}

+ (nullable instancetype)itemFromDictionary:(NSDictionary<NSString *, id> *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    
    YunaItem *item = [[YunaItem alloc] init];
    item.uuid = dict[@"uuid"] ?: [[NSUUID UUID] UUIDString];
    item.type = [dict[@"type"] integerValue];
    item.timestamp = [dict[@"timestamp"] doubleValue];
    item.isPinned = [dict[@"isPinned"] boolValue];
    item.itemSize = [dict[@"itemSize"] unsignedIntegerValue];
    
    item.text = dict[@"text"];
    item.imageRelativePath = dict[@"imageRelativePath"];
    item.imageBase64 = dict[@"imageBase64"];
    item.fileURLString = dict[@"fileURLString"];
    item.title = dict[@"title"];
    
    return item;
}

- (NSString *)displayTitle {
    if (self.title && self.title.length > 0) {
        return self.title;
    }
    switch (self.type) {
        case YunaItemTypeText:
            return [YunaItem truncatedPreviewForString:self.text maxChars:30];
        case YunaItemTypeImage:
            return @"Image";
        case YunaItemTypeURL:
            return self.text ?: @"URL Link";
        case YunaItemTypeFile:
            return [self.fileURLString lastPathComponent] ?: @"File";
    }
    return @"Item";
}

- (NSString *)displaySubtitle {
    switch (self.type) {
        case YunaItemTypeText: {
            NSUInteger chars = self.text.length;
            return [NSString stringWithFormat:@"%lu characters • %@", (unsigned long)chars, [self relativeTimeString]];
        }
        case YunaItemTypeImage: {
            if (self.itemSize > 0) {
                NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:self.itemSize countStyle:NSByteCountFormatterCountStyleFile];
                return [NSString stringWithFormat:@"%@ • %@", sizeStr, [self relativeTimeString]];
            }
            return [NSString stringWithFormat:@"Photo • %@", [self relativeTimeString]];
        }
        case YunaItemTypeURL:
            return [NSString stringWithFormat:@"Web Link • %@", [self relativeTimeString]];
        case YunaItemTypeFile: {
            if (self.itemSize > 0) {
                NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:self.itemSize countStyle:NSByteCountFormatterCountStyleFile];
                return [NSString stringWithFormat:@"%@ • %@", sizeStr, [self relativeTimeString]];
            }
            return [NSString stringWithFormat:@"File • %@", [self relativeTimeString]];
        }
    }
    return [self relativeTimeString];
}

- (NSString *)relativeTimeString {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval diff = now - self.timestamp;
    
    if (diff < 5.0) return @"Just now";
    if (diff < 60.0) return [NSString stringWithFormat:@"%.0fs ago", diff];
    if (diff < 3600.0) return [NSString stringWithFormat:@"%.0fm ago", diff / 60.0];
    if (diff < 86400.0) return [NSString stringWithFormat:@"%.0fh ago", diff / 3600.0];
    if (diff < 172800.0) return @"Yesterday";
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateStyle = NSDateFormatterShortStyle;
    df.timeStyle = NSDateFormatterNoStyle;
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.timestamp]];
}

- (nullable UIImage *)loadImage {
    if (self.type != YunaItemTypeImage) {
        return nil;
    }
    if (self.imageBase64 && self.imageBase64.length > 0) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:self.imageBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (data && data.length > 0) {
            UIImage *img = [UIImage imageWithData:data];
            if (img) return img;
        }
    }
    if (self.imageRelativePath && self.imageRelativePath.length > 0) {
        NSString *fullPath = [YUNA_IMAGES_DIR stringByAppendingPathComponent:self.imageRelativePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
            return [UIImage imageWithContentsOfFile:fullPath];
        }
    }
    return nil;
}

@end
