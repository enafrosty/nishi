#ifndef NISHI_ROOTLESS_H
#define NISHI_ROOTLESS_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef JBROOT_PREFIX
#define JBROOT_PREFIX "/var/jb"
#endif

#ifndef JBROOT_PATH
#define JBROOT_PATH(path) (JBROOT_PREFIX path)
#endif

// Convert legacy path to rootless /var/jb if needed
static inline NSString *nishi_jbroot(NSString *path) {
    if (!path) return nil;
    if ([path hasPrefix:@"/var/jb"]) return path;
    return [@"/var/jb" stringByAppendingPathComponent:path];
}

#ifdef __cplusplus
}
#endif

#endif /* NISHI_ROOTLESS_H */
