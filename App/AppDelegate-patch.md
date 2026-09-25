# AppDelegate patch — fork `Turbo-Boost-Switcher`, replace auth with XPC

All call sites that prompt today live in `AppDelegate.m` and go through
`SystemCommands loadModuleWithAuthRef:/unLoadModuleWithAuthRef:` (which use
the deprecated `AuthorizationExecuteWithPrivileges`). `isModuleLoaded`
(`kextstat` grep) needs NO root — keep it for status display.

## 1. Add files to the Xcode target

- `App/HelperManager.h`, `App/HelperManager.m`
- `Shared/TurboBoostHelperProtocol.h`
- Link `ServiceManagement.framework` (for `SMJobBless`).

## 2. `receiveWakeNote:` — the password-on-wake culprit

BEFORE (`AppDelegate.m`, today):

```objc
if ([SystemCommands isModuleLoaded]) {
    // ... AuthorizationCreate + AuthorizationCopyRights (prompts!) ...
    [SystemCommands unLoadModuleWithAuthRef:authorizationRef];
    [SystemCommands loadModuleWithAuthRef:authorizationRef];
}
```

AFTER (no auth UI; helper is already root and also re-applies itself):

```objc
#import "HelperManager.h"

- (void)receiveWakeNote:(NSNotification *)note {
    [HelperManager reapplyAfterWake:^(BOOL success, NSString *msg) {
        NSLog(@"wake reapply: %d %@", success, msg);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(updateStatus) withObject:nil afterDelay:0.5];
            [self performSelector:@selector(updateStatus) withObject:nil afterDelay:1.5];
        });
    }];
    // keep the delayed updateStatus calls; drop the whole authorizationRef block
}
```

Keep the `updateStatus` delays — the MSR rewrite takes ~1s after wake.

## 3. `disableTurboBoost` / `enableTurboBoost`

BEFORE: `AuthorizationCreate…` + `[SystemCommands loadModuleWithAuthRef:]`.

AFTER:

```objc
- (void)disableTurboBoost {
    [HelperManager setTurboBoostDisabled:YES completion:^(BOOL ok, NSString *msg) {
        NSLog(@"disable: %d %@", ok, msg);
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateStatus]; });
    }];
}
- (void)enableTurboBoost {
    [HelperManager setTurboBoostDisabled:NO completion:^(BOOL ok, NSString *msg) {
        NSLog(@"enable: %d %@", ok, msg);
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateStatus]; });
    }];
}
```

`authorizationRef` ivar can then be deleted from `AppDelegate.h`.

## 4. One-time helper install

On first toggle (or a new "Install Helper…" menu item):

```objc
NSError *err = nil;
if (![HelperManager ensureHelperBlessed:&err]) {
    // Signing not configured yet → tell the user to run:
    //   sudo scripts/install-dev.sh
    NSLog(@"SMJobBless failed: %@", err);
}
```

## 5. Project modernization (required to build with Xcode 16)

- Deployment target 10.6/10.7 → set to 10.13+ (Xcode 16 minimum).
- Sign app + helper with the SAME Team (`CL2J5F345D` here).
- Add `SMPrivilegedExecutables` to app Info.plist
  (see `App/InfoPlistAdditions.plist`), `SMAuthorizedClients` to helper
  (see `Helper/Helper-Info.plist`), values from `scripts/make-requirements.sh`.
- `AuthorizationExecuteWithPrivileges` is deprecated since 10.7 — after this
  patch nothing calls it anymore.

## 6. What you can delete later

`SystemCommands runTaskAsAdmin:withAuthRef:`, `loadModuleWithPath:`,
`unloadModuleWithPath:`, `readCurrentCpuFreqWithAuthRef:` (powermetrics via
auth) — dead after the migration. Keep `isModuleLoaded*`, SMC temp/fan code.
