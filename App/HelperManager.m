// HelperManager.m — app-side XPC client. Clean-room code, GPL-2.0.
#import "HelperManager.h"
#import "TurboBoostHelperProtocol.h"
#import <ServiceManagement/ServiceManagement.h>

static NSString * const kHelperLabel = @"com.local.TurboBoostSwitcher.helper";

@implementation HelperManager

+ (NSXPCConnection *)freshConnection {
    NSXPCConnection *c = [[NSXPCConnection alloc]
        initWithMachServiceName:kHelperLabel
                        options:NSXPCConnectionPrivileged];
    c.remoteObjectInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(TurboBoostHelperProtocol)];
    return c;
}

+ (BOOL)ensureHelperBlessed:(NSError **)error {
    // SMJobBless installs /Library/PrivilegedHelperTools/<label> as root.
    // Requires: app + helper signed with the SAME Team ID, SMPrivilegedExecutables
    // in app Info.plist, SMAuthorizedClients in helper Info.plist.
    AuthorizationItem authItem = { kSMRightBlessPrivilegedHelper, 0, NULL, 0 };
    AuthorizationRights authRights = { 1, &authItem };
    AuthorizationFlags flags = kAuthorizationFlagDefaults
                             | kAuthorizationFlagInteractionAllowed
                             | kAuthorizationFlagPreAuthorize
                             | kAuthorizationFlagExtendRights;
    AuthorizationRef authRef = NULL;
    OSStatus st = AuthorizationCreate(&authRights, kAuthorizationEmptyEnvironment,
                                      flags, &authRef);
    if (st != errAuthorizationSuccess) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:st
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"AuthorizationCreate failed"}];
        return NO;
    }
    Boolean ok = NO;
    // SMJobBless is deprecated in 13+ in favor of SMAppService, but still
    // functional on Sequoia and matches this helper's architecture.
    // (Tahoe migration: repackage as SMAppService daemon.)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFErrorRef cfErr = NULL;
    ok = SMJobBless(kSMDomainSystemLaunchd,
                    (__bridge CFStringRef)kHelperLabel, authRef, &cfErr);
#pragma clang diagnostic pop
    if (authRef) AuthorizationFree(authRef, kAuthorizationFlagDefaults);
    if (!ok && error) {
        *error = cfErr ? CFBridgingRelease(cfErr)
                       : [NSError errorWithDomain:@"HelperManager" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"SMJobBless failed"}];
    } else if (cfErr) {
        CFRelease(cfErr);
    }
    return ok;
}

+ (void)setTurboBoostDisabled:(BOOL)disabled
                  completion:(void (^)(BOOL, NSString * _Nullable))completion {
    NSXPCConnection *c = [self freshConnection];
    [c resume];
    id<TurboBoostHelperProtocol> proxy =
        [c remoteObjectProxyWithErrorHandler:^(NSError *err) {
            completion(NO, err.localizedDescription);
            [c invalidate];
        }];
    [proxy setTurboBoostDisabled:disabled
                       withReply:^(BOOL success, NSString *msg) {
        completion(success, msg);
        [c invalidate];
    }];
}

+ (void)reapplyAfterWake:(void (^)(BOOL, NSString * _Nullable))completion {
    NSXPCConnection *c = [self freshConnection];
    [c resume];
    id<TurboBoostHelperProtocol> proxy =
        [c remoteObjectProxyWithErrorHandler:^(NSError *err) {
            completion(NO, err.localizedDescription);
            [c invalidate];
        }];
    [proxy reapplyDesiredStateWithReply:^(BOOL success, NSString *msg) {
        completion(success, msg);
        [c invalidate];
    }];
}

+ (void)getTurboBoostDisabled:(void (^)(BOOL))completion {
    NSXPCConnection *c = [self freshConnection];
    [c resume];
    id<TurboBoostHelperProtocol> proxy =
        [c remoteObjectProxyWithErrorHandler:^(NSError *err) {
            completion(NO);
            [c invalidate];
        }];
    [proxy getTurboBoostDisabledWithReply:^(BOOL disabled) {
        completion(disabled);
        [c invalidate];
    }];
}

@end
