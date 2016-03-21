//
//  PacketUDP.h
//  Neumob SDK iOS
//
//  Created by Dan Park on 3/3/16.
//  Copyright (c) 2016 Neumob, Inc. All rights reserved.
//

#import "NMPacketUDP.h"
#import "NMNetDiagnostic.h"

// NI_MAXHOST
#include <netdb.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>

@protocol NMPacketUDPDelegate <NSObject>
@optional

- (void)packetUDP:(NMPacketUDP *)packetUDP didStartWithAddress:(NSData *)address;
- (void)packetUDP:(NMPacketUDP *)packetUDP didStopWithError:(NSError *)error;

- (void)packetUDP:(NMPacketUDP *)packetUDP didSendData:(NSData *)data toAddress:(NSData *)address;
- (void)packetUDP:(NMPacketUDP *)packetUDP didFailToSendData:(NSData *)data toAddress:(NSData *)address error:(NSError *)error;
- (void)packetUDP:(NMPacketUDP *)packetUDP didReceiveData:(NSData *)data fromAddress:(NSData *)address;
- (void)packetUDP:(NMPacketUDP *)packetUDP didReceiveError:(NSError *)error;
@end


// Supports IP6 and IP4 (an IPv4-mapped address)

@interface NMPacketUDP() <NMPacketUDPDelegate>

@property (nonatomic, weak) id<NMPacketUDPDelegate> delegate;
@property (nonatomic, copy, readwrite) NSString *hostName;
@property (nonatomic, copy, readwrite) NSData *hostAddress;
@property (nonatomic, assign, readwrite) NSUInteger port;
@end

@implementation NMPacketUDP {
    dispatch_queue_t socketQueue;
    CFHostRef _cfHost;
    CFSocketRef _cfSocket;
}

- (id)init {
    self = [super init];
    if (self != nil) {
        _delegate = self;
        socketQueue = dispatch_queue_create("sq.neumob", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)sendData:(NSData *)data toAddress:(NSData *)address {
    
    assert(data != nil);
    assert( (address == nil) || ([address length] <= sizeof(struct sockaddr_storage)) );
    
    int sock = CFSocketGetNative(self->_cfSocket);
    assert(sock >= 0);
    
    const struct sockaddr *addrPtr;
    socklen_t addrLen;
    
    if (address == nil) {
        address = self.hostAddress;
        assert(address != nil);
        addrPtr = NULL;
        addrLen = 0;
    } else {
        addrPtr = [address bytes];
        addrLen = (socklen_t) [address length];
    }
    
    int error;
    ssize_t bytesWritten = sendto(sock, [data bytes], [data length], 0, addrPtr, addrLen);
    if (bytesWritten < 0) {
        error = errno;
    } else  if (bytesWritten == 0) {
        error = EPIPE;
    } else {
        assert( (NSUInteger) bytesWritten == [data length] );
        error = 0;
    }
    
    if (error == 0) {
        if ( (self.delegate != nil) && [self.delegate respondsToSelector:@selector(packetUDP:didSendData:toAddress:)] ) {
            [self.delegate packetUDP:self didSendData:data toAddress:address];
        }
    } else {
        if ( (self.delegate != nil) && [self.delegate respondsToSelector:@selector(packetUDP:didFailToSendData:toAddress:error:)] ) {
            [self.delegate packetUDP:self didFailToSendData:data toAddress:address error:[NSError errorWithDomain:NSPOSIXErrorDomain code:error userInfo:nil]];
        }
    }
}

- (void)readData {
    int                     error;
    struct sockaddr_storage address;
    socklen_t               addressLen;
    uint8_t                 buffer[65536];
    ssize_t                 bytesRead;
    
    int sock = CFSocketGetNative(self->_cfSocket);
    assert(sock >= 0);
    
    addressLen = sizeof(address);
    bytesRead = recvfrom(sock, buffer, sizeof(buffer), 0, (struct sockaddr *) &address, &addressLen);
    if (bytesRead < 0) {
        error = errno;
    } else if (bytesRead == 0) {
        error = EPIPE;
    } else {
        NSData *    dataObj;
        NSData *    addrObj;
        
        error = 0;
        
        dataObj = [NSData dataWithBytes:buffer length:(NSUInteger) bytesRead];
        assert(dataObj != nil);
        addrObj = [NSData dataWithBytes:&address  length:addressLen  ];
        assert(addrObj != nil);

        if ( (self.delegate != nil) && [self.delegate respondsToSelector:@selector(packetUDP:didReceiveData:fromAddress:)] ) {
            [self.delegate packetUDP:self didReceiveData:dataObj fromAddress:addrObj];
        }
    }
    
    if (error != 0) {
        if ( (self.delegate != nil) && [self.delegate respondsToSelector:@selector(packetUDP:didReceiveError:)] ) {
            [self.delegate packetUDP:self didReceiveError:[NSError errorWithDomain:NSPOSIXErrorDomain code:error userInfo:nil]];
        }
    }
}

static void SocketReadCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    
    NMPacketUDP *obj = (__bridge NMPacketUDP *) info;
    
    assert([obj isKindOfClass:[NMPacketUDP class]]);
    assert(s == obj->_cfSocket);
    assert(type == kCFSocketReadCallBack);
    assert(address == nil);
    assert(data == nil);
    
    [obj readData];
}

- (BOOL)setupSocketConnectedToAddress:(NSData *)address
                                 port:(NSUInteger)port
                                error:(NSError **)errorPtr {
    
    sa_family_t             socketFamily;
    int                     err;
    int                     junk;
    int                     sock;
    const CFSocketContext   context = { 0, (__bridge void *) (self), NULL, NULL, NULL };
    CFRunLoopSourceRef      rls;
    
    assert( (address == nil) || ([address length] <= sizeof(struct sockaddr_storage)) );
    assert(port < 65536);
    
    assert(self->_cfSocket == NULL);
    
    err = 0;
    sock = socket(AF_INET6, SOCK_DGRAM, 0);
    if (sock >= 0) {
        socketFamily = AF_INET6;
    } else {
        sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (sock >= 0) {
            socketFamily = AF_INET;
        } else {
            err = errno;
            socketFamily = 0;
            assert(err != 0);
        }
    }
    
    if (err == 0) {
        struct sockaddr_storage addr;
        struct sockaddr_in *    addr4;
        struct sockaddr_in6 *   addr6;
        
        addr4 = (struct sockaddr_in * ) &addr;
        addr6 = (struct sockaddr_in6 *) &addr;
        
        memset(&addr, 0, sizeof(addr));
        if (address == nil) {
        } else {
            if ([address length] > sizeof(addr)) {
                assert(NO);
                [address getBytes:&addr length:sizeof(addr)];
            } else {
                [address getBytes:&addr length:[address length]];
            }
            if (addr.ss_family == AF_INET) {
                if (socketFamily == AF_INET6) {
                    
                    struct in_addr ipv4Addr;
                    ipv4Addr = addr4->sin_addr;
                    
                    addr6->sin6_len         = sizeof(*addr6);
                    addr6->sin6_family      = AF_INET6;
                    addr6->sin6_port        = htons(port);
                    addr6->sin6_addr.__u6_addr.__u6_addr32[0] = 0;
                    addr6->sin6_addr.__u6_addr.__u6_addr32[1] = 0;
                    addr6->sin6_addr.__u6_addr.__u6_addr16[4] = 0;
                    addr6->sin6_addr.__u6_addr.__u6_addr16[5] = 0xffff;
                    addr6->sin6_addr.__u6_addr.__u6_addr32[3] = ipv4Addr.s_addr;
                } else {
                    addr4->sin_port = htons(port);
                }
            } else {
                assert(addr.ss_family == AF_INET6);
                addr6->sin6_port        = htons(port);
            }
            if ( (addr.ss_family == AF_INET) && (socketFamily == AF_INET6) ) {
                addr6->sin6_len         = sizeof(*addr6);
                addr6->sin6_port        = htons(port);
                addr6->sin6_addr        = in6addr_any;
            }
        }
        if (address == nil) {
            err = bind(sock, (const struct sockaddr *) &addr, addr.ss_len);
        } else {
            err = connect(sock, (const struct sockaddr *) &addr, addr.ss_len);
        }
        if (err < 0) {
            err = errno;
        }
    }
    
    if (err == 0) {
        int flags;
        
        flags = fcntl(sock, F_GETFL);
        err = fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        if (err < 0) {
            err = errno;
        }
    }
    
    if (err == 0) {
        self->_cfSocket = CFSocketCreateWithNative(NULL, sock, kCFSocketReadCallBack, SocketReadCallback, &context);
        
        assert( CFSocketGetSocketFlags(self->_cfSocket) & kCFSocketCloseOnInvalidate );
        sock = -1;
        
        rls = CFSocketCreateRunLoopSource(NULL, self->_cfSocket, 0);
        assert(rls != NULL);
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
        
        CFRelease(rls);
    }
    
    if (sock != -1) {
        junk = close(sock);
        assert(junk == 0);
    }
    assert( (err == 0) == (self->_cfSocket != NULL) );
    if ( (self->_cfSocket == NULL) && (errorPtr != NULL) ) {
        *errorPtr = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
    }
    
    return (err == 0);
}

- (void)startServerOnPort:(NSUInteger)port {
    assert( (port > 0) && (port < 65536) );

    assert(self.port == 0);     // don't try and start a started object
    if (self.port == 0) {
        BOOL        success;
        NSError *   error;

        // Create a fully configured socket.
        
        success = [self setupSocketConnectedToAddress:nil port:port error:&error];

        // If we can create the socket, we're good to go.  Otherwise, we report an error
        // to the delegate.

        if (success) {
            self.port = port;

            if ( (self.delegate != nil) && [self.delegate respondsToSelector:@selector(packetUDP:didStartWithAddress:)] ) {
                CFDataRef   localAddress;
                
                localAddress = CFSocketCopyAddress(self->_cfSocket);
                assert(localAddress != NULL);
                
                [self.delegate packetUDP:self didStartWithAddress:(__bridge NSData *) localAddress];

                CFRelease(localAddress);
            }
        } else {
            [self stopWithError:error];
        }
    }
}

- (void)hostResolutionDone {
    assert(self.port != 0);
    assert(self->_cfHost != NULL);
    assert(self->_cfSocket == NULL);
    assert(self.hostAddress == nil);
    
    Boolean resolved;
    NSError *error = nil;
    NSArray *resolvedAddresses = (__bridge NSArray *) CFHostGetAddressing(self->_cfHost, &resolved);
    if ( resolved && (resolvedAddresses != nil) ) {
        for (NSData * address in resolvedAddresses) {
            
            NSUInteger addrLen = [address length];
            const struct sockaddr *addrPtr = (const struct sockaddr *) [address bytes];
            assert(addrLen >= sizeof(struct sockaddr));

            BOOL success = NO;
            if ((addrPtr->sa_family == AF_INET) || (addrPtr->sa_family == AF_INET6)) {
                success = [self setupSocketConnectedToAddress:address port:self.port error:&error];
                if (success) {
                    CFDataRef   hostAddress;
                    
                    hostAddress = CFSocketCopyPeerAddress(self->_cfSocket);
                    assert(hostAddress != NULL);
                    
                    self.hostAddress = (__bridge NSData *) hostAddress;
                    
                    CFRelease(hostAddress);
                }
            }
            if (success) {
                break;
            }
        }
    }
    
    if ( (self.hostAddress == nil) && (error == nil) ) {
        error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
    }

    if (error == nil) {
        [self stopHostResolution];

        if ( (self.delegate != nil) && [self.delegate respondsToSelector:@selector(packetUDP:didStartWithAddress:)] ) {
            [self.delegate packetUDP:self didStartWithAddress:self.hostAddress];
        }
    } else {
        [self stopWithError:error];
    }
}

static void HostResolveCallback(CFHostRef theHost, CFHostInfoType typeInfo, const CFStreamError *error, void *info) {
    NMPacketUDP *obj = (__bridge NMPacketUDP *) info;
    assert([obj isKindOfClass:[NMPacketUDP class]]);
    
    #pragma unused(theHost)
    assert(theHost == obj->_cfHost);
    #pragma unused(typeInfo)
    assert(typeInfo == kCFHostAddresses);
    
    if ( (error != NULL) && (error->domain != 0) ) {
        [obj stopWithStreamError:*error];
    } else {
        [obj hostResolutionDone];
    }
}

+ (void)sendExceptionInQueue:(NSException *)exception
                    function:(const char *)function
                        line:(NSUInteger)line {
    NSString *string = [NSString stringWithFormat:@"function:%s (line:%d) exception:%@ callStack:%@",
                                        function, line, exception, exception.callStackSymbols];
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [self sendDataInQueue:data];
}

+ (void)sendStringInQueue:(NSString*)string{
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [self sendDataInQueue:data];
}

+ (void)sendDataInQueue:(NSData*)data{
    dispatch_async(dispatch_get_main_queue(), ^() {
        static NMPacketUDP *packetUDP = nil;
        packetUDP = [NMPacketUDP new];
        packetUDP.dataUDP = data;
        [packetUDP connectToHost];
    });
}

- (void)connectToHost{
#define RLOG_PORT 53509
#define RLOG_SERVER	@"logs3.papertrailapp.com"

    NSUInteger port = RLOG_PORT;
    NSString *host = RLOG_SERVER;
    [self startConnectedToHostName:host port:port];
}

- (void)startConnectedToHostName:(NSString *)hostName port:(NSUInteger)port {
    assert(hostName != nil);
    assert( (port > 0) && (port < 65536) );
    
    assert(self.port == 0);
    if (self.port == 0) {
        Boolean             success;
        CFHostClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
        CFStreamError       streamError;

        assert(self->_cfHost == NULL);

        self->_cfHost = CFHostCreateWithName(NULL, (__bridge CFStringRef) hostName);
        assert(self->_cfHost != NULL);
        
        CFHostSetClient(self->_cfHost, HostResolveCallback, &context);
        
        CFHostScheduleWithRunLoop(self->_cfHost, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        
        success = CFHostStartInfoResolution(self->_cfHost, kCFHostAddresses, &streamError);
        if (success) {
            self.hostName = hostName;
            self.port = port;
        } else {
            [self stopWithStreamError:streamError];
        }
    }
}

- (void)sendData:(NSData *)data {
    if (self.hostAddress == nil) {
        assert(NO);
    } else {
        [self sendData:data toAddress:nil];
    }
}

- (void)stopHostResolution {
    if (self->_cfHost != NULL) {
        CFHostSetClient(self->_cfHost, NULL, NULL);
        CFHostCancelInfoResolution(self->_cfHost, kCFHostAddresses);
        CFHostUnscheduleFromRunLoop(self->_cfHost, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(self->_cfHost);
        self->_cfHost = NULL;
    }
}

- (void)stop {
    self.hostName = nil;
    self.hostAddress = nil;
    self.port = 0;
    [self stopHostResolution];
    if (self->_cfSocket != NULL) {
        CFSocketInvalidate(self->_cfSocket);
        CFRelease(self->_cfSocket);
        self->_cfSocket = NULL;
    }
}

- (void)nop:(id)object {}

- (void)stopWithError:(NSError *)error {
    assert(error != nil);
    [self stop];
    if ( (self.delegate != nil) && [self.delegate respondsToSelector:@selector(packetUDP:didStopWithError:)] ) {
        [self performSelector:@selector(nop:) withObject:self afterDelay:0.0];
        [self.delegate packetUDP:self didStopWithError:error];
    }
}

- (void)stopWithStreamError:(CFStreamError)streamError {
    NSDictionary *userInfo = nil;

    if (streamError.domain == kCFStreamErrorDomainNetDB) {
        userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInteger:streamError.error], kCFGetAddrInfoFailureKey,
            nil
        ];
    } else {
        userInfo = nil;
    }

    NSError *error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorUnknown userInfo:userInfo];
    assert(error != nil);
    
    [self stopWithError:error];
}

#pragma mark - NMPacketUDPDelegates

- (void)packetUDP:(NMPacketUDP *)packetUDP didReceiveData:(NSData *)data fromAddress:(NSData *)address {
    NMLog(@"%s: address:%@ data:%@", __func__, [NMNetDiagnostic stringForAddress:address], [NMNetDiagnostic stringData:data]);
}

- (void)packetUDP:(NMPacketUDP *)packetUDP didReceiveError:(NSError *)error {
    if (error) {
        NMLog(@"%s: error:%@", __func__, [NMNetDiagnostic stringError:error]);
    } else {
        NMLog(@"%s", __func__);
    }
}

- (void)packetUDP:(NMPacketUDP *)packetUDP didSendData:(NSData *)data toAddress:(NSData *)address {
    NMLog(@"%s: address:%@ data:%@", __func__, [NMNetDiagnostic stringForAddress:address], [NMNetDiagnostic stringData:data]);
}

- (void)packetUDP:(NMPacketUDP *)packetUDP didFailToSendData:(NSData *)data toAddress:(NSData *)address error:(NSError *)error {
    if (error) {
        NMLog(@"%s: address:%@ error:%@", __func__, [NMNetDiagnostic stringForAddress:address], [NMNetDiagnostic stringError:error]);
    } else {
        NMLog(@"%s", __func__);
    }
}

- (void)packetUDP:(NMPacketUDP *)packetUDP didStartWithAddress:(NSData *)address {
    NMLog(@"%s: address:%@", __func__, [NMNetDiagnostic stringForAddress:address]);
    
    if (packetUDP.dataUDP) {
        dispatch_async(socketQueue, ^() {
            [packetUDP sendData:packetUDP.dataUDP];
        });
    }
}

- (void)packetUDP:(NMPacketUDP *)packetUDP didStopWithError:(NSError *)error {
    if (error) {
        NMLog(@"%s: error:%@", __func__, [NMNetDiagnostic stringError:error]);
    } else {
        NMLog(@"%s", __func__);
    }
}

@end
