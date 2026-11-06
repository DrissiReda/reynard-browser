//
//  AppleSSOBridge.m
//  Reynard
//

#import "AppleSSOBridge.h"
#import <dlfcn.h>
#import <objc/message.h>

static void *AppSSOHandle(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/AppSSO.framework/AppSSO", RTLD_NOW);
    });
    return handle;
}

// Option keys are exported NSString constants; read them rather than guessing their values.
static NSString *_Nullable OptionKey(const char *name) {
    void *handle = AppSSOHandle();
    NSString *__unsafe_unretained *key = handle ? (NSString *__unsafe_unretained *)dlsym(handle, name) : NULL;
    return key ? *key : nil;
}

// SOAuthorizationOptionInitiatingAction values (AppSSO enum).
enum { InitiatingActionRedirect = 0, InitiatingActionPopUp = 1 };

/// One authorization; implements the (all-optional) SOAuthorizationDelegate methods.
@interface AppleSSOSession : NSObject
@property (nonatomic, strong) id authorization;
@property (nonatomic, copy, nullable) AppleSSOCompletion completion;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong, nullable) AppleSSOSession *retainSelf; // AppSSO holds its delegate weakly
@end

@implementation AppleSSOSession

- (void)finishWithStatus:(NSInteger)status
                 headers:(NSDictionary *)headers
                 cookies:(NSArray *)cookies
                    body:(NSData *)body
                 handled:(BOOL)handled {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppleSSOCompletion completion = self.completion;
        self.completion = nil;
        self.retainSelf = nil;
        if (completion) completion(status, headers, cookies, body, handled);
    });
}

- (void)notHandled {
    [self finishWithStatus:0 headers:@{} cookies:@[] body:NSData.data handled:NO];
}

- (void)authorizationDidNotHandle:(id)authorization { [self notHandled]; }
- (void)authorizationDidComplete:(id)authorization { [self notHandled]; }
- (void)authorization:(id)authorization didCompleteWithHTTPAuthorizationHeaders:(NSDictionary *)headers { [self notHandled]; }
- (void)authorization:(id)authorization didCompleteWithError:(NSError *)error {
    NSLog(@"[AppleSSO] error %@", error);
    [self notHandled];
}
- (void)authorizationDidCancel:(id)authorization {
    [self finishWithStatus:-1 headers:@{} cookies:@[] body:NSData.data handled:YES];
}

- (void)authorization:(id)authorization didCompleteWithHTTPResponse:(NSHTTPURLResponse *)response httpBody:(NSData *)body {
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id name, id value, BOOL *stop) {
        if ([name isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class]
            && [name caseInsensitiveCompare:@"Set-Cookie"] != NSOrderedSame) {
            headers[name] = value;
        }
    }];
    // allHeaderFields joins Set-Cookie with commas (which also appear in Expires):
    // parse properly and send one Set-Cookie line per cookie.
    NSMutableArray<NSString *> *cookies = [NSMutableArray array];
    NSURL *url = response.URL;
    for (NSHTTPCookie *cookie in url ? [NSHTTPCookie cookiesWithResponseHeaderFields:response.allHeaderFields forURL:url] : @[]) {
        NSMutableString *line = [NSMutableString stringWithFormat:@"%@=%@; Path=%@", cookie.name, cookie.value, cookie.path ?: @"/"];
        if ([cookie.domain hasPrefix:@"."]) [line appendFormat:@"; Domain=%@", cookie.domain];
        if (cookie.expiresDate) [line appendFormat:@"; Max-Age=%ld", (long)MAX(0, cookie.expiresDate.timeIntervalSinceNow)];
        if (cookie.isSecure) [line appendString:@"; Secure"];
        if (cookie.isHTTPOnly) [line appendString:@"; HttpOnly"];
        if (cookie.sameSitePolicy) [line appendFormat:@"; SameSite=%@", cookie.sameSitePolicy];
        [cookies addObject:line];
    }
    [self finishWithStatus:response.statusCode headers:headers cookies:cookies body:body ?: NSData.data handled:YES];
}

- (void)authorization:(id)authorization presentViewController:(UIViewController *)viewController withCompletion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = self.presenter;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        if (!presenter) {
            if (completion) completion(NO, nil);
            return;
        }
        [presenter presentViewController:viewController animated:YES completion:^{
            if (completion) completion(YES, nil);
        }];
    });
}

@end

@implementation AppleSSOBridge

+ (void)authorizeURL:(NSURL *)url
             headers:(NSDictionary<NSString *, NSString *> *)headers
     initiatorOrigin:(NSString *)origin
         userGesture:(BOOL)userGesture
               popup:(BOOL)popup
           presenter:(UIViewController *)presenter
          completion:(AppleSSOCompletion)completion {
    Class SOAuthorization = AppSSOHandle() ? NSClassFromString(@"SOAuthorization") : nil;
    SEL canPerform = NSSelectorFromString(@"canPerformAuthorizationWithURL:responseCode:");
    SEL begin = NSSelectorFromString(@"beginAuthorizationWithURL:httpHeaders:httpBody:");
    if (!SOAuthorization || ![SOAuthorization respondsToSelector:canPerform]
        || ![SOAuthorization instancesRespondToSelector:begin]
        || !((BOOL (*)(id, SEL, NSURL *, NSInteger))objc_msgSend)(SOAuthorization, canPerform, url, 0)) {
        completion(0, @{}, @[], NSData.data, NO);
        return;
    }

    AppleSSOSession *session = [AppleSSOSession new];
    session.completion = completion;
    session.presenter = presenter;
    session.retainSelf = session;
    id authorization = [SOAuthorization new];
    session.authorization = authorization;

    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    NSString *key;
    if ((key = OptionKey("SOAuthorizationOptionUserActionInitiated"))) options[key] = @(userGesture);
    if ((key = OptionKey("SOAuthorizationOptionInitiatorOrigin")) && origin.length) options[key] = origin;
    if ((key = OptionKey("SOAuthorizationOptionInitiatingAction"))) options[key] = @(popup ? InitiatingActionPopUp : InitiatingActionRedirect);

    @try {
        [authorization setValue:session forKey:@"delegate"];
        [authorization setValue:options forKey:@"authorizationOptions"];
        // We implement authorization:presentViewController:withCompletion:.
        [authorization setValue:@(presenter != nil) forKey:@"enableEmbeddedAuthorizationViewController"];
        ((void (*)(id, SEL, NSURL *, NSDictionary *, NSData *))objc_msgSend)(authorization, begin, url, headers, nil);
    } @catch (NSException *exception) {
        NSLog(@"[AppleSSO] %@", exception);
        [session notHandled];
    }
}

@end
