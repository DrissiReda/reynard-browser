//
//  Utils.h
//  Reynard
//
//  Created by Minh Ton on 12/4/26.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

BOOL getEntitlementValue(NSString *key);
void updateJetsamControl(pid_t pid);
int spawnRoot(NSString *path, NSArray<NSString *> *args);
// Name of the installed app that claims url as a universal link, or nil. Calls back on the main queue.
void appLinkTargetName(NSURL *url, void (^completion)(NSString * _Nullable name));

NS_ASSUME_NONNULL_END
