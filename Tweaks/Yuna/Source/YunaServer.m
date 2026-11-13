#import "YunaServer.h"
#import "YunaStorage.h"
#import "YunaItem.h"
#import "Headers/YunaCommon.h"
#import <notify.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

#define YUNA_MAX_IPC_PAYLOAD (512 * 1024)

@interface YunaServer () {
    dispatch_queue_t _workerQueue;
    dispatch_queue_t _socketReadQueue;
    BOOL _isObserving;
    int _tokenExt;
    int _tokenCmd;
    int _tokenClipboard;
    int _slotTokens[YUNA_IPC_SLOT_COUNT];
    int _serverSock;
    dispatch_source_t _acceptSource;
}
@end

@implementation YunaServer

+ (instancetype)sharedServer {
    static YunaServer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[YunaServer alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workerQueue = dispatch_queue_create("com.frosty.yuna.server", DISPATCH_QUEUE_SERIAL);
        _socketReadQueue = dispatch_queue_create("com.frosty.yuna.server.sockread", DISPATCH_QUEUE_CONCURRENT);
        _isObserving = NO;
        _tokenExt = 0;
        _tokenCmd = 0;
        _tokenClipboard = 0;
        _serverSock = -1;
        for (int i = 0; i < YUNA_IPC_SLOT_COUNT; i++) {
            _slotTokens[i] = 0;
        }
    }
    return self;
}

- (void)dealloc {
    [self stopServer];
}

- (void)startServer {
    if (_isObserving) return;
    _isObserving = YES;

    YunaLog(@"Starting Yuna IPC server in SpringBoard (loopback TCP + Darwin ring)...");

    // Pre-register Darwin IPC ring slot tokens once
    for (int i = 0; i < YUNA_IPC_SLOT_COUNT; i++) {
        NSString *name = [NSString stringWithFormat:@"com.frosty.yuna/ipc.%d", i];
        int tok = 0;
        if (notify_register_check([name UTF8String], &tok) == NOTIFY_STATUS_OK) {
            _slotTokens[i] = tok;
        }
    }

    [self startLoopbackTCPServer];

    __weak typeof(self) weakSelf = self;

    // 1. Darwin state-ring fallback IPC for offline/sandboxed apps
    notify_register_dispatch(YUNA_EXT_PASTEBOARD_NOTIFICATION, &_tokenExt, _workerQueue, ^(int token) {
        [weakSelf handleIncomingSlotRingIPC];
    });

    // 2. Sandboxed IPC Command Dispatch: pin, delete, clear
    notify_register_dispatch(YUNA_CMD_NOTIFICATION, &_tokenCmd, _workerQueue, ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        if (state == 0) return;
        uint8_t action = (state >> 56) & 0xFF;
        uint64_t hashId = state & 0x00FFFFFFFFFFFFFFULL;

        if (action == YUNA_CMD_TOGGLE_PIN) {
            [[YunaStorage sharedInstance] togglePinnedForHash:hashId];
        } else if (action == YUNA_CMD_DELETE) {
            [[YunaStorage sharedInstance] deleteItemWithHash:hashId];
        } else if (action == YUNA_CMD_CLEAR_UNPINNED) {
            [[YunaStorage sharedInstance] clearUnpinnedItems];
        }
    });

    // 3. Reload when an external unsandboxed process updates history.plist (skip self-writes)
    notify_register_dispatch(YUNA_CLIPBOARD_NOTIFICATION, &_tokenClipboard, _workerQueue, ^(int t) {
        [[YunaStorage sharedInstance] reloadFromDiskIfModifiedExternally];
    });
}

- (void)startLoopbackTCPServer {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        YunaLog(@"Failed to create IPC socket: %d", errno);
        return;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(YUNA_IPC_TCP_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        YunaLog(@"Failed to bind loopback IPC socket on %d: %d", YUNA_IPC_TCP_PORT, errno);
        close(fd);
        return;
    }

    if (listen(fd, 16) != 0) {
        YunaLog(@"Failed to listen on loopback IPC socket: %d", errno);
        close(fd);
        return;
    }

    _serverSock = fd;
    __weak typeof(self) weakSelf = self;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _workerQueue);
    dispatch_source_set_event_handler(source, ^{
        YunaServer *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf acceptPendingConnections];
    });
    dispatch_source_set_cancel_handler(source, ^{
        if (fd >= 0) {
            close(fd);
        }
    });

    _acceptSource = source;
    dispatch_resume(source);
}

- (void)acceptPendingConnections {
    while (_serverSock >= 0) {
        struct sockaddr_in clientAddr;
        socklen_t addrLen = sizeof(clientAddr);
        int clientFD = accept(_serverSock, (struct sockaddr *)&clientAddr, &addrLen);
        if (clientFD < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                break;
            }
            break;
        }

        // Only accept local loopback connections
        if (ntohl(clientAddr.sin_addr.s_addr) != INADDR_LOOPBACK) {
            close(clientFD);
            continue;
        }

        int yes = 1;
#ifdef SO_NOSIGPIPE
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
        int cFlags = fcntl(clientFD, F_GETFL, 0);
        if (cFlags >= 0 && (cFlags & O_NONBLOCK)) {
            fcntl(clientFD, F_SETFL, cFlags & ~O_NONBLOCK);
        }
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 300000;
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        __weak typeof(self) weakSelf = self;
        dispatch_async(_socketReadQueue, ^{
            [weakSelf readAndProcessClientSocket:clientFD];
        });
    }
}

static BOOL yna_readExact(int fd, void *buf, size_t len) {
    uint8_t *ptr = (uint8_t *)buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t n = recv(fd, ptr, remaining, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return NO;
        }
        ptr += (size_t)n;
        remaining -= (size_t)n;
    }
    return YES;
}

- (void)readAndProcessClientSocket:(int)clientFD {
    @autoreleasepool {
        uint32_t netLen = 0;
        if (!yna_readExact(clientFD, &netLen, sizeof(netLen))) {
            close(clientFD);
            return;
        }

        uint32_t payloadLen = ntohl(netLen);
        if (payloadLen == 0 || payloadLen > YUNA_MAX_IPC_PAYLOAD) {
            close(clientFD);
            return;
        }

        NSMutableData *data = [NSMutableData dataWithLength:payloadLen];
        if (!data || !yna_readExact(clientFD, data.mutableBytes, payloadLen)) {
            close(clientFD);
            return;
        }
        close(clientFD);

        NSError *error = nil;
        NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data
                                                                       options:NSPropertyListImmutable
                                                                        format:NULL
                                                                         error:&error];
        if (!dict || ![dict isKindOfClass:[NSDictionary class]]) return;

        YunaItem *item = [YunaItem itemFromDictionary:dict];
        if (!item) return;

        [[YunaStorage sharedInstance] addItem:item];
    }
}

- (void)handleIncomingSlotRingIPC {
    @autoreleasepool {
        if (_slotTokens[0] <= 0) return;

        uint64_t header = 0;
        if (notify_get_state(_slotTokens[0], &header) != NOTIFY_STATUS_OK || header == 0) {
            return;
        }

        uint32_t byteLen = (uint32_t)(header & 0xFFFFFFFFULL);
        uint32_t itemType = (uint32_t)((header >> 32) & 0xFFFFFFFFULL);
        uint32_t maxBytes = (YUNA_IPC_SLOT_COUNT - 1) * 8;
        if (byteLen == 0 || byteLen > maxBytes) {
            notify_set_state(_slotTokens[0], 0);
            return;
        }

        uint8_t buf[256];
        memset(buf, 0, sizeof(buf));
        uint32_t slotCount = (byteLen + 7) / 8;
        for (uint32_t i = 0; i < slotCount && (i + 1) < YUNA_IPC_SLOT_COUNT; i++) {
            uint64_t val = 0;
            if (_slotTokens[i + 1] > 0) {
                notify_get_state(_slotTokens[i + 1], &val);
            }
            for (int b = 0; b < 8; b++) {
                uint32_t offset = i * 8 + (uint32_t)b;
                if (offset < byteLen) {
                    buf[offset] = (uint8_t)((val >> (b * 8)) & 0xFF);
                }
            }
        }

        notify_set_state(_slotTokens[0], 0);

        NSString *str = [[NSString alloc] initWithBytes:buf length:byteLen encoding:NSUTF8StringEncoding];
        if (!str || str.length == 0) return;

        YunaItem *item = nil;
        if (itemType == YunaItemTypeURL) {
            NSURL *url = [NSURL URLWithString:str];
            item = url ? [YunaItem itemWithURL:url] : [YunaItem itemWithText:str];
        } else {
            item = [YunaItem itemWithText:str];
        }

        if (item) {
            [[YunaStorage sharedInstance] addItem:item];
        }
    }
}

- (void)stopServer {
    if (!_isObserving) return;
    _isObserving = NO;

    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
        _serverSock = -1;
    } else if (_serverSock >= 0) {
        close(_serverSock);
        _serverSock = -1;
    }

    if (_tokenExt > 0) { notify_cancel(_tokenExt); _tokenExt = 0; }
    if (_tokenCmd > 0) { notify_cancel(_tokenCmd); _tokenCmd = 0; }
    if (_tokenClipboard > 0) { notify_cancel(_tokenClipboard); _tokenClipboard = 0; }

    for (int i = 0; i < YUNA_IPC_SLOT_COUNT; i++) {
        if (_slotTokens[i] > 0) {
            notify_cancel(_slotTokens[i]);
            _slotTokens[i] = 0;
        }
    }
}

@end
