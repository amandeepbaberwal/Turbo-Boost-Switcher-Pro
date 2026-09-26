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

@implementation TurboBoostHelper

#pragma mark - plist state

- (BOOL)persistedDisabled {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if (!d) return NO; // default: turbo ON (safe default, matches stock behavior)
    return [d[@"disabled"] boolValue];
}

- (void)persistDisabled:(BOOL)disabled {
    [[NSFileManager defaultManager] createDirectoryAtPath:kSupportDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"disabled": @(disabled)} writeToFile:kStatePath atomically:YES];
}

#pragma mark - task runner (already root, no Authorization Services needed)

- (int)runTask:(NSString *)launchPath args:(NSArray<NSString *> *)args output:(NSString **)out {
    NSPipe *pipe = [NSPipe pipe];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = launchPath;
    t.arguments = args;
    t.standardOutput = pipe;
    t.standardError = pipe;
    @try { [t launch]; } @catch (NSException *e) {
        NSLog(@"[TBHelper] launch %@ failed: %@", launchPath, e);
        if (out) *out = e.reason ?: @"launch failed";
        return -1;
    }
    [t waitUntilExit];
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
    if (![self persistedDisabled]) { reply(YES, @"desired=enabled, nothing to do"); return; }
    NSString *msg = nil;
    BOOL ok = [self cycleKext:&msg];
    NSLog(@"[TBHelper] reapply (wanted OFF) -> %d (%@)", ok, msg);
    reply(ok, msg);
}

- (void)getVersionWithReply:(void (^)(NSString * _Nonnull))reply {
    reply(TBHelperVersion);
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
                    output:&out];
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
    reply(@{@"disabled": @(disabled),
            @"freqMaxMHz": @(maxMHz),
            @"freqAvgMHz": @(nCPU ? (long)(sumMHz / nCPU) : -1),
            @"tempC": @(tempC),
            @"pkgW": @(pkgW)});
}

#pragma mark - boot + wake

- (void)restoreStateAtBoot {
    if (![self persistedDisabled]) {
        NSLog(@"[TBHelper] boot: desired=enabled, nothing to do");
        return;
    }
    NSString *msg = nil;
    BOOL ok = [self loadKext:&msg];
    NSLog(@"[TBHelper] boot restore (wanted OFF) -> %d (%@)", ok, msg);
}

- (void)handleSystemWake {
    if (![self persistedDisabled]) return;
    // MSR may not be writable the instant we wake; 1s delay like the app's 0.5/1.5s retries.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *msg = nil;
        BOOL ok = [self cycleKext:&msg];
        NSLog(@"[TBHelper] wake reapply -> %d (%@)", ok, msg);
    });
}

@end
