//
//  NMNetDiagnostic.h
//  Neumob SDK iOS
//
//  Created by Dan Park on 3/3/16.
//  Copyright © 2016 Neumob, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NMNetDiagnostic : NSObject

+ (NSString*)stringData:(NSData *)data;
+ (NSString*)stringForAddress:(NSData*)address;
+ (NSString*)stringError:(NSError *)error;
@end
