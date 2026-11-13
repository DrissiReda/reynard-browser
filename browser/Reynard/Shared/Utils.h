//
//  Utils.h
//  Reynard
//
//  Created by Minh Ton on 12/4/26.
//

@import Foundation;
@import UIKit;

NS_ASSUME_NONNULL_BEGIN

BOOL getEntitlementValue(NSString *key);
void updateJetsamControl(pid_t pid);
int spawnRoot(NSString *path, NSArray<NSString *> *args);
// Name and bundle id of the installed app that claims url as a universal link, or nil. Calls back on the main queue.
void appLinkTargetName(NSURL *url, void (^completion)(NSString * _Nullable name, NSString * _Nullable bundleID));
// Home screen icon of an installed app, or nil.
UIImage * _Nullable appIconImage(NSString *bundleID);

NS_ASSUME_NONNULL_END
