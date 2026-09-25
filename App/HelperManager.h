// HelperManager.h — app-side XPC client. Drop into the forked TBS Xcode project.
// Replaces AuthorizationRef-based kext loading. Clean-room code, GPL-2.0.
#import <Foundation/Foundation.h>

@interface HelperManager : NSObject

// One-time privileged install. Asks for admin password ONCE via SMJobBless,
// then never again. Returns NO + error if signing isn't configured yet
// (fall back to scripts/install-dev.sh in that case).
+ (BOOL)ensureHelperBlessed:(NSError **)error;

// Toggle. Completion runs on a background queue — dispatch to main for UI.
+ (void)setTurboBoostDisabled:(BOOL)disabled
                  completion:(void (^)(BOOL success, NSString * _Nullable message))completion;

// Re-assert persisted state (call from receiveWakeNote). No auth UI.
+ (void)reapplyAfterWake:(void (^)(BOOL success, NSString * _Nullable message))completion;

+ (void)getTurboBoostDisabled:(void (^)(BOOL disabled))completion;

@end
