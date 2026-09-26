// TurboBoostHelper.m
// Privileged (root) XPC helper implementation.
// Runs as root via LaunchDaemon, so kextload/kextunload need no auth.
// Persists desired state; re-applies on boot and on wake.
// Clean-room code, GPL-2.0. Kext itself is upstream's com.rugarciap.DisableTurboBoost.
#import "TurboBoostHelper.h"

static NSString * const kKextBundleID = @"com.rugarciap.DisableTurboBoost";
// NOTE: the kext is loaded BY BUNDLE ID, never by file path. This exact kext
// (UUID 2BECDC3A…) ships in the AuxKC boot collection, so
// `kmutil load -b` succeeds while every path-based load (kextload, kextutil)
// dies in staging auth with KMError 29 (unsigned legacy kext, Sequoia shims
// both tools onto kmutil). Unload was always ID-based and always worked.
static NSString * const kSupportDir = @"/Library/Application Support/TurboBoostSwitcher";
static NSString * const kStatePath = @"/Library/Application Support/TurboBoostSwitcher/wanted-state.plist";
// VoltageShift integration (vendored GPL-3.0, see VShift/): the CLI lives in
// our support dir, its kext in /Library/Extensions (needs the SIP kext
// exemption + one approval — the Setup panel walks the user through it).
static NSString * const kVSCLIPath = @"/Library/Application Support/TurboBoostSwitcher/voltageshift";
static NSString * const kVSKextPath = @"/Library/Extensions/VoltageShift.kext";
static NSString * const kVSKextBundleID = @"com.sicreative.VoltageShift";

@implementation TurboBoostHelper {
    NSString *_lastBootRestore; // visible in Settings; explains slow-boot races
}

- (NSString *)clockNow {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [[NSDateFormatter alloc] init]; f.dateFormat = @"HH:mm:ss"; });
    return [f stringFromDate:[NSDate date]];
}

#pragma mark - plist state

- (NSMutableDictionary *)stateDict {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveStateDict:(NSDictionary *)d {
    [[NSFileManager defaultManager] createDirectoryAtPath:kSupportDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [d writeToFile:kStatePath atomically:YES];
}

- (BOOL)persistedDisabled {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if (!d) return NO; // default: turbo ON (safe default, matches stock behavior)
    return [d[@"disabled"] boolValue];
}

- (void)persistDisabled:(BOOL)disabled {
    NSMutableDictionary *d = [self stateDict];
    d[@"disabled"] = @(disabled);
    [self saveStateDict:d];
}

// PL state. Stock Apple defaults (100/125 on this chassis) = do-no-harm
// default. First run with no keys adopts whatever is live (so an existing
// manual `voltageshift power X Y` setup isn't clobbered), else stock.
- (long)persistedPL1 { return [[self stateDict][@"pl1"] longValue] ?: 100; }
- (long)persistedPL2 { return [[self stateDict][@"pl2"] longValue] ?: 125; }

- (void)persistPL1:(long)pl1 PL2:(long)pl2 {
    NSMutableDictionary *d = [self stateDict];
    d[@"pl1"] = @(pl1); d[@"pl2"] = @(pl2);
    [self saveStateDict:d];
}

- (void)ensurePLState {
    NSMutableDictionary *d = [self stateDict];
    if (d[@"pl1"] && d[@"pl2"]) return;
    long live1 = 0, live2 = 0;
    if ([self readLivePowerLimitsPL1:&live1 PL2:&live2]) {
        d[@"pl1"] = @(live1); d[@"pl2"] = @(live2);
        NSLog(@"[TBHelper] adopted live PL1=%ld PL2=%ld", live1, live2);
    } else {
        d[@"pl1"] = @100; d[@"pl2"] = @125;
    }
    [self saveStateDict:d];
}

#pragma mark - task runner (already root, no Authorization Services needed)

- (int)runTask:(NSString *)launchPath args:(NSArray<NSString *> *)args output:(NSString **)out {
    return [self runTask:launchPath args:args output:out timeout:0];
}

// timeout<=0 waits forever (kext ops). Positive timeout kills the task and
// returns -2, so one stuck tool (e.g. powermetrics) can never wedge XPC:
// the menu opens a fresh connection per call, but a wedged exported object
// would still serialize-block that connection's queue.
- (int)runTask:(NSString *)launchPath args:(NSArray<NSString *> *)args output:(NSString **)out timeout:(NSTimeInterval)timeout {
    NSPipe *pipe = [NSPipe pipe];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = launchPath;
    t.arguments = args;
    t.standardOutput = pipe;
    t.standardError = pipe;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    t.terminationHandler = ^(NSTask *task __unused) { dispatch_semaphore_signal(sem); };
    @try { [t launch]; } @catch (NSException *e) {
        NSLog(@"[TBHelper] launch %@ failed: %@", launchPath, e);
        if (out) *out = e.reason ?: @"launch failed";
        return -1;
    }
    if (timeout > 0) {
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
            @try { [t terminate]; } @catch (NSException *e __unused) {}
            [t waitUntilExit];
            if (out) *out = @"timed out";
            NSLog(@"[TBHelper] %@ timed out after %.0fs", launchPath, timeout);
            return -2;
        }
    } else {
        [t waitUntilExit];
    }
    if (out) {
        NSData *d = [[pipe fileHandleForReading] readDataToEndOfFile];
        *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    }
    return (int)t.terminationStatus;
}

#pragma mark - kext ops

- (BOOL)isKextLoaded {
    NSString *out = nil;
    // kextstat returns 0 even when grep finds nothing, so inspect output text
    [self runTask:@"/usr/sbin/kextstat" args:@[] output:&out];
    return out && [out rangeOfString:kKextBundleID].location != NSNotFound;
}

- (BOOL)loadKext:(NSString **)msg {
    if ([self isKextLoaded]) { if (msg) *msg = @"already loaded"; return YES; }
    NSString *out = nil;
    int st = [self runTask:@"/usr/bin/kmutil" args:@[@"load", @"-b", kKextBundleID] output:&out];
    if (msg) *msg = out;
    if (st != 0) NSLog(@"[TBHelper] kmutil load -b failed (%d): %@", st, out);
    return st == 0;
}

- (BOOL)unloadKext:(NSString **)msg {
    if (![self isKextLoaded]) { if (msg) *msg = @"already unloaded"; return YES; }
    NSString *out = nil;
    int st = [self runTask:@"/sbin/kextunload" args:@[@"-b", kKextBundleID] output:&out];
    if (msg) *msg = out;
    if (st != 0) NSLog(@"[TBHelper] kextunload failed (%d): %@", st, out);
    return st == 0;
}

// The wake cycle: MSR is reset but the kext still shows as loaded,
// so a plain load is a no-op — must unload THEN load to rewrite MSR 0x1A0.
// Mirrors AppDelegate -receiveWakeNote, minus the password prompt.
- (BOOL)cycleKext:(NSString **)msg {
    NSString *m1 = nil, *m2 = nil;
    [self unloadKext:&m1]; // ignore failure (may already be effectively off)
    BOOL ok = [self loadKext:&m2];
    if (msg) *msg = [NSString stringWithFormat:@"unload: %@ | load: %@", m1 ?: @"-", m2 ?: @"-"];
    return ok;
}

#pragma mark - VoltageShift power limits

- (BOOL)isVSKextLoaded {
    NSString *out = nil;
    [self runTask:@"/usr/sbin/kextstat" args:@[] output:&out];
    return out && [out rangeOfString:kVSKextBundleID].location != NSNotFound;
}

- (BOOL)ensureVSKext:(NSString **)msg {
    if ([self isVSKextLoaded]) { if (msg) *msg = @"already loaded"; return YES; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVSKextPath]) {
        if (msg) *msg = @"VoltageShift.kext not installed (see Setup)";
        return NO;
    }
    NSString *out = nil;
    [self runTask:@"/usr/sbin/chown" args:@[@"-R", @"root:wheel", kVSKextPath] output:nil];
    int st = [self runTask:@"/usr/bin/kextutil" args:@[kVSKextPath] output:&out];
    if (msg) *msg = out;
    if (st != 0) NSLog(@"[TBHelper] VS kextutil failed (%d): %@", st, out);
    return st == 0 && [self isVSKextLoaded];
}

// Parse "OC_Locked Turbo_Disabled PL1: 45W PL2: 60W" from `voltageshift info`.
- (BOOL)readLivePowerLimitsPL1:(long *)pl1 PL2:(long *)pl2 {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:kVSCLIPath]) return NO;
    NSString *out = nil;
    int st = [self runTask:kVSCLIPath args:@[@"info"] output:&out];
    if (st != 0 || !out) return NO;
    NSScanner *s = [NSScanner scannerWithString:out];
    long v1 = 0, v2 = 0;
    if (![s scanUpToString:@"PL1:" intoString:NULL]) return NO;
    [s scanString:@"PL1:" intoString:NULL];
    long long t1 = 0;
    if (![s scanLongLong:&t1] || t1 <= 0) return NO;
    if (![s scanUpToString:@"PL2:" intoString:NULL]) return NO;
    [s scanString:@"PL2:" intoString:NULL];
    long long t2 = 0;
    if (![s scanLongLong:&t2] || t2 <= 0) return NO;
    v1 = (long)t1; v2 = (long)t2;
    if (pl1) *pl1 = v1;
    if (pl2) *pl2 = v2;
    return YES;
}

- (BOOL)applyPowerLimitsPL1:(long)pl1 PL2:(long)pl2 msg:(NSString **)msg {
    if (pl1 < 5) pl1 = 5; if (pl1 > 125) pl1 = 125;
    if (pl2 < 10) pl2 = 10; if (pl2 > 200) pl2 = 200;
    NSString *m = nil;
    if (![self ensureVSKext:&m]) {
        if (msg) *msg = [@"VS kext unavailable: " stringByAppendingString:m ?: @"-"];
        return NO;
    }
    NSString *out = nil;
    NSString *s1 = [NSString stringWithFormat:@"%ld", pl1];
    NSString *s2 = [NSString stringWithFormat:@"%ld", pl2];
    int st = [self runTask:kVSCLIPath args:@[@"power", s1, s2] output:&out];
    if (msg) *msg = out;
    if (st != 0) NSLog(@"[TBHelper] voltageshift power failed (%d): %@", st, out);
    return st == 0;
}

#pragma mark - XPC protocol

- (void)setTurboBoostDisabled:(BOOL)disabled
                   withReply:(void (^)(BOOL, NSString * _Nullable))reply {
    [self persistDisabled:disabled];
    NSString *msg = nil;
    BOOL ok = disabled ? [self loadKext:&msg] : [self unloadKext:&msg];
    NSLog(@"[TBHelper] setDisabled=%d -> %d (%@)", disabled, ok, msg);
    reply(ok, msg);
}

- (void)getTurboBoostDisabledWithReply:(void (^)(BOOL))reply {
    reply([self isKextLoaded]);
}

- (void)reapplyDesiredStateWithReply:(void (^)(BOOL, NSString * _Nullable))reply {
    NSString *msg = nil;
    [self reapplyAll:&msg];
    NSLog(@"[TBHelper] reapply -> %@", msg);
    reply(YES, msg);
}

- (void)getVersionWithReply:(void (^)(NSString * _Nonnull))reply {
    reply(TBHelperVersion);
}

- (void)setPowerLimitsPL1:(long)pl1 PL2:(long)pl2
                withReply:(void (^)(BOOL, NSString * _Nullable))reply {
    [self ensurePLState];
    NSString *msg = nil;
    BOOL ok = [self applyPowerLimitsPL1:pl1 PL2:pl2 msg:&msg];
    if (ok) {
        [self persistPL1:pl1 PL2:pl2];
        // Read back what the chip actually accepted (it may clamp).
        long r1 = 0, r2 = 0;
        if ([self readLivePowerLimitsPL1:&r1 PL2:&r2]) {
            msg = [NSString stringWithFormat:@"%@ | chip reports PL1:%ldW PL2:%ldW",
                   msg ?: @"", r1, r2];
        }
    }
    NSLog(@"[TBHelper] setPL %ld/%ld -> %d (%@)", pl1, pl2, ok, msg);
    reply(ok, msg);
}

- (void)getPowerLimitsWithReply:(void (^)(long, long))reply {
    [self ensurePLState];
    // Prefer live chip truth when readable; persisted intent otherwise.
    long r1 = 0, r2 = 0;
    if ([self readLivePowerLimitsPL1:&r1 PL2:&r2]) { reply(r1, r2); return; }
    reply([self persistedPL1], [self persistedPL2]);
}

- (void)getStatsWithReply:(void (^)(NSDictionary * _Nonnull))reply {
    BOOL disabled = [self isKextLoaded];
    // powermetrics needs root — which is exactly what this helper is.
    // Short 200ms sample keeps each menu poll cheap. cpu_power gives
    // per-CPU "fraction of nominal (XXXX Mhz)" lines; smc gives die temp.
    NSString *out = nil;
    int st = [self runTask:@"/usr/bin/powermetrics"
                      args:@[@"-n", @"1", @"-i", @"200",
                             @"--samplers", @"cpu_power,smc"]
                    output:&out timeout:8];
    long maxMHz = -1, sumMHz = 0, nCPU = 0;
    double tempC = -1, pkgW = -1;
    if (st == 0 && out) {
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            BOOL hasCPU = [t rangeOfString:@"CPU"].location != NSNotFound;
            // Observed Intel format: "CPU Average frequency as fraction of
            // nominal: 66.15% (1720.00 Mhz)". Skip the "System Average" rollup.
            if ([t rangeOfString:@"frequency as fraction of nominal:"].location != NSNotFound
                && [t rangeOfString:@"System "].location == NSNotFound) {
                NSRange lp = [t rangeOfString:@"("];
                if (lp.location != NSNotFound) {
                    NSScanner *s = [NSScanner scannerWithString:
                                    [t substringFromIndex:lp.location + 1]];
                    double v = 0;
                    if ([s scanDouble:&v] && v > 0) {
                        long m = lround(v);
                        if (m > maxMHz) maxMHz = m;
                        sumMHz += m; nCPU++;
                    }
                }
                continue;
            }
            // Legacy/alternate: "CPU 0 frequency: 2599 MHz"
            if (hasCPU && [t rangeOfString:@"frequency:"].location != NSNotFound) {
                NSScanner *s = [NSScanner scannerWithString:t];
                [s scanUpToString:@"frequency:" intoString:NULL];
                [s scanString:@"frequency:" intoString:NULL];
                long long v = 0;
                if ([s scanLongLong:&v] && v > 0) {
                    if ((long)v > maxMHz) maxMHz = (long)v;
                    sumMHz += v; nCPU++;
                }
                continue;
            }
            // smc sampler: "CPU die temperature: 57.19 C" (first one wins;
            // on Intel the CPU line comes first, before GPU/ANE).
            if (tempC < 0 && [t rangeOfString:@"die temperature"].location != NSNotFound) {
                NSScanner *s = [NSScanner scannerWithString:t];
                [s scanUpToString:@"temperature:" intoString:NULL];
                [s scanString:@"temperature:" intoString:NULL];
                double v = 0;
                if ([s scanDouble:&v] && v > 0) tempC = v;
            }
            // cpu_power sampler: "Intel energy model derived package power (CPUs+GT+SA): 1.15W"
            if (pkgW < 0 && [t rangeOfString:@"package power"].location != NSNotFound) {
                NSRange colon = [t rangeOfString:@":" options:NSBackwardsSearch];
                if (colon.location != NSNotFound) {
                    NSScanner *s = [NSScanner scannerWithString:[t substringFromIndex:colon.location + 1]];
                    double v = 0;
                    if ([s scanDouble:&v] && v >= 0) pkgW = v;
                }
            }
        }
    } else {
        NSLog(@"[TBHelper] powermetrics failed (%d)", st);
    }
    // Health flags so the menu can explain itself instead of showing bare n/a.
    BOOL vsCLI = [[NSFileManager defaultManager] isExecutableFileAtPath:kVSCLIPath];
    NSString *sipOut = nil;
    [self runTask:@"/usr/bin/csrutil" args:@[@"status"] output:&sipOut timeout:5];
    NSString *sip = @"unknown";
    if (sipOut) {
        if ([sipOut rangeOfString:@"Kext Signing: disabled"].location != NSNotFound) sip = @"exempt";
        else if ([sipOut rangeOfString:@"System Integrity Protection status: enabled."].location != NSNotFound) sip = @"full";
    }
    reply(@{@"disabled": @(disabled),
            @"freqMaxMHz": @(maxMHz),
            @"freqAvgMHz": @(nCPU ? (long)(sumMHz / nCPU) : -1),
            @"tempC": @(tempC),
            @"pkgW": @(pkgW),
            @"pl1": @([self persistedPL1]),
            @"pl2": @([self persistedPL2]),
            @"vsKext": @([self isVSKextLoaded]),
            @"vsCLI": @(vsCLI),
            @"sip": sip,
            @"bootRestore": _lastBootRestore ?: @"not run yet"});
}

#pragma mark - boot + wake

- (void)reapplyAll:(NSString **)msg {
    // Turbo MSR + package power limits are both volatile: re-assert together.
    NSString *m1 = nil, *m2 = nil;
    BOOL okT = YES;
    if ([self persistedDisabled]) okT = [self cycleKext:&m1];
    [self ensurePLState];
    BOOL okP = [self applyPowerLimitsPL1:[self persistedPL1] PL2:[self persistedPL2] msg:&m2];
    if (msg) *msg = [NSString stringWithFormat:@"turbo: %@ | pl: %@",
                     okT ? (m1 ?: @"ok") : @"SKIPPED-enabled", m2 ?: @"-"];
    if (!okT || !okP) NSLog(@"[TBHelper] reapply partial turbo=%d pl=%d", okT, okP);
}

- (void)restoreStateAtBoot {
    _lastBootRestore = @"running…";
    [self attemptBootRestore:1];
}

// Verified restore: slow boots (kext staging, MSR readiness) used to leave
// PL/turbo unapplied with no trace. Now each attempt verifies live state
// and retries at +10s/+30s before giving up with a visible status.
- (void)attemptBootRestore:(int)tryNo {
    [self ensurePLState];
    if ([self persistedDisabled]) {
        NSString *m = nil;
        [self loadKext:&m];
    }
    NSString *m2 = nil;
    [self applyPowerLimitsPL1:[self persistedPL1] PL2:[self persistedPL2] msg:&m2];
    BOOL turboOK = ![self persistedDisabled] || [self isKextLoaded];
    long r1 = 0, r2 = 0;
    BOOL plOK = [self readLivePowerLimitsPL1:&r1 PL2:&r2];
    if (turboOK && plOK) {
        _lastBootRestore = [NSString stringWithFormat:@"ok %@ (turbo %@, PL %ld/%ld)",
                            [self clockNow],
                            [self persistedDisabled] ? @"OFF" : @"ON",
                            [self persistedPL1], [self persistedPL2]];
        NSLog(@"[TBHelper] boot restore verified: %@", _lastBootRestore);
    } else if (tryNo < 3) {
        _lastBootRestore = [NSString stringWithFormat:@"verifying… (try %d)", tryNo];
        int delay = tryNo == 1 ? 10 : 30;
        NSLog(@"[TBHelper] boot restore incomplete (turbo=%d pl=%d), retry in %ds", turboOK, plOK, delay);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self attemptBootRestore:tryNo + 1];
        });
    } else {
        _lastBootRestore = @"partial — see /var/log/tbhelper.log";
        NSLog(@"[TBHelper] boot restore partial after 3 tries (turbo=%d pl=%d)", turboOK, plOK);
    }
}

- (void)handleSystemWake {
    // MSRs may not be writable the instant we wake; 1s delay as before.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *msg = nil;
        [self reapplyAll:&msg];
        NSLog(@"[TBHelper] wake reapply -> %@", msg);
    });
}

@end
