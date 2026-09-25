// TurboBoostHelper.h
// Privileged (root) XPC helper. Owns all kext load/unload.
// Clean-room code, GPL-2.0.
#import <Foundation/Foundation.h>
#import "TurboBoostHelperProtocol.h"

@interface TurboBoostHelper : NSObject <TurboBoostHelperProtocol>

// Called once at daemon start (boot) to restore persisted state.
- (void)restoreStateAtBoot;

// Called on system wake (MSR 0x1A0 is wiped on CPU power loss).
- (void)handleSystemWake;

@end
