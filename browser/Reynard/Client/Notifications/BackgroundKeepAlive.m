//
//  BackgroundKeepAlive.m
//  Reynard
//

#import "BackgroundKeepAlive.h"
#import <dlfcn.h>

// RunningBoardServices SPI, as used by WebKit's ProcessAssertionCocoa.mm.
@interface RBSTarget : NSObject
+ (instancetype)targetWithPid:(pid_t)pid;
@end
@interface RBSDomainAttribute : NSObject
+ (instancetype)attributeWithDomain:(NSString *)domain name:(NSString *)name;
@end
@interface RBSAssertion : NSObject
- (instancetype)initWithExplanation:(NSString *)explanation target:(RBSTarget *)target attributes:(NSArray *)attributes;
- (BOOL)acquireWithError:(NSError **)error;
@end

static NSMutableArray *sAssertions;

@implementation BackgroundKeepAlive

+ (NSString *)acquireForPID:(pid_t)pid {
    dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
    Class targetClass = NSClassFromString(@"RBSTarget");
    Class attributeClass = NSClassFromString(@"RBSDomainAttribute");
    Class assertionClass = NSClassFromString(@"RBSAssertion");
    if (!targetClass || !attributeClass || !assertionClass) {
        return @"RunningBoardServices unavailable";
    }
    if (!sAssertions) {
        sAssertions = [NSMutableArray array];
    }

    RBSTarget *target = [targetClass targetWithPid:pid];
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    // Each one separately: a missing entitlement fails only its own assertion.
    // ponytail: names from WebKit; "Background" is capped at 30s on iOS.
    for (NSString *name in @[ @"UnboundedNetworking", @"Foreground" ]) {
        RBSDomainAttribute *attribute = [attributeClass attributeWithDomain:@"com.apple.webkit" name:name];
        RBSAssertion *assertion = [[assertionClass alloc] initWithExplanation:@"Reynard web push"
                                                                       target:target
                                                                   attributes:@[ attribute ]];
        NSError *error = nil;
        if ([assertion acquireWithError:&error]) {
            [sAssertions addObject:assertion];
            [results addObject:[NSString stringWithFormat:@"%@: ok", name]];
        } else {
            [results addObject:[NSString stringWithFormat:@"%@: %@", name, error.localizedDescription ?: @"failed"]];
        }
    }
    return [results componentsJoinedByString:@", "];
}

@end
