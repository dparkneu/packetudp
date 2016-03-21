//
//  PacketUDP.h
//  Neumob SDK iOS
//
//  Created by Dan Park on 3/3/16.
//  Copyright (c) 2016 Neumob, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NMPacketUDP : NSObject
@property (nonatomic, strong) NSData *dataUDP;
@property (nonatomic, copy, readonly ) NSString *hostName;
@property (nonatomic, copy, readonly ) NSData *hostAddress;
@property (nonatomic, assign, readonly ) NSUInteger port;

+ (void)sendExceptionInQueue:(NSException *)exception
                    function:(const char *)function
                        line:(NSUInteger)line;
@end


