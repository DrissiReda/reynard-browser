//
//  BackgroundKeepAlive.h
//  Reynard
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Holds private RunningBoard assertions so a TrollStore-installed Reynard
/// (and its Gecko child processes) keep running in the background, which
/// keeps the Web Push connection open.
@interface BackgroundKeepAlive : NSObject
/// Acquires the assertions for `pid`. Returns a description of each result.
+ (NSString *)acquireForPID:(pid_t)pid;
@end

NS_ASSUME_NONNULL_END
