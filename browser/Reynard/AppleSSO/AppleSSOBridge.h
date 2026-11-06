//
//  AppleSSOBridge.h
//  Reynard
//
//  Native "Sign in with Apple" for web pages, done the way WebKit does it
//  (Source/WebKit/UIProcess/Cocoa/SOAuthorization): the private AppSSO
//  SOAuthorization class shows Apple's sheet (Face ID, Hide My Email) and
//  returns the appleid.apple.com HTTP response the page would have received.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// status > 0: serve this response. status == -1: user cancelled, stop the load.
/// handled == NO: AppSSO declined, load the normal web page.
typedef void (^AppleSSOCompletion)(NSInteger status,
                                   NSDictionary<NSString *, NSString *> *headers,
                                   NSArray<NSString *> *cookies,
                                   NSData *body,
                                   BOOL handled);

@interface AppleSSOBridge : NSObject
+ (void)authorizeURL:(NSURL *)url
             headers:(NSDictionary<NSString *, NSString *> *)headers
     initiatorOrigin:(nullable NSString *)origin
         userGesture:(BOOL)userGesture
               popup:(BOOL)popup
           presenter:(nullable UIViewController *)presenter
          completion:(AppleSSOCompletion)completion;
@end

NS_ASSUME_NONNULL_END
