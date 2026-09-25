// TurboBoostHelperProtocol.h
// Shared XPC protocol between the app and the privileged helper.
// Clean-room code, GPL-2.0 to match upstream rugarciap/Turbo-Boost-Switcher.
#import <Foundation/Foundation.h>

static NSString * const TBHelperMachServiceName = @"com.local.TurboBoostSwitcher.helper";
static NSString * const TBHelperVersion = @"1.0";

@protocol TurboBoostHelperProtocol

// desiredState YES = turbo boost OFF (kext loaded), NO = turbo ON (kext unloaded)
- (void)setTurboBoostDisabled:(BOOL)disabled
                   withReply:(void (^)(BOOL success, NSString * _Nullable message))reply;

- (void)getTurboBoostDisabledWithReply:(void (^)(BOOL disabled))reply;

// Re-assert persisted desired state (used after wake + at boot)
- (void)reapplyDesiredStateWithReply:(void (^)(BOOL success, NSString * _Nullable message))reply;

- (void)getVersionWithReply:(void (^)(NSString * _Nonnull version))reply;

// One-shot stats for the menu bar. No auth needed (helper is root).
// stats = @{@"disabled": @(BOOL),
//           @"freqMaxMHz": @(long, -1 unknown),
//           @"freqAvgMHz": @(long, -1 unknown),
//           @"tempC": @(double, -1 unknown)}
- (void)getStatsWithReply:(void (^)(NSDictionary * _Nonnull stats))reply;

@end
