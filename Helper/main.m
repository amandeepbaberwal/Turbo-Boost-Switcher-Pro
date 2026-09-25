// main.m — privileged helper daemon entry point.
// Listens on TBHelperMachServiceName via NSXPCListener, restores desired
// kext state at boot, re-applies after wake. Clean-room code, GPL-2.0.
#import <Foundation/Foundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOMessage.h>
#import "TurboBoostHelper.h"
#import "TurboBoostHelperProtocol.h"

@interface ServiceDelegate : NSObject <NSXPCListenerDelegate>
@property (strong) TurboBoostHelper *helper;
@end

@implementation ServiceDelegate
- (BOOL)listener:(NSXPCListener *)listener
    shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    // NOTE: for personal single-user use we accept the local client.
    // Before distributing, verify peer code signing here (auditToken).
    newConnection.exportedInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(TurboBoostHelperProtocol)];
    newConnection.exportedObject = self.helper;
    [newConnection resume];
    return YES;
}
@end

// IOKit power callback: re-assert MSR after CPU power loss.
static io_connect_t powerConnection = IO_OBJECT_NULL;

static void PowerCallback(void *refCon, io_service_t service,
                          natural_t msgType, void *msgArgument) {
    ServiceDelegate *delegate = (__bridge ServiceDelegate *)refCon;
    switch (msgType) {
        case kIOMessageSystemHasPoweredOn:
            NSLog(@"[TBHelper] system woke");
            [delegate.helper handleSystemWake];
            break;
        case kIOMessageSystemWillSleep:
            IOAllowPowerChange(powerConnection, (long)msgArgument);
            break;
        default:
            break;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TurboBoostHelper *helper = [[TurboBoostHelper alloc] init];
        ServiceDelegate *delegate = [[ServiceDelegate alloc] init];
        delegate.helper = helper;

        // 1. XPC listener (LaunchDaemon plist advertises this MachService)
        NSXPCListener *listener =
            [[NSXPCListener alloc] initWithMachServiceName:TBHelperMachServiceName];
        listener.delegate = delegate;
        [listener resume];
        NSLog(@"[TBHelper] v%@ listening on %@", TBHelperVersion, TBHelperMachServiceName);

        // 2. Wake notifications
        IONotificationPortRef port = NULL;
        io_object_t notifier = IO_OBJECT_NULL;
        powerConnection = IORegisterForSystemPower((__bridge void *)delegate,
                                                  &port, PowerCallback, &notifier);
        if (powerConnection) {
            CFRunLoopAddSource(CFRunLoopGetCurrent(),
                               IONotificationPortGetRunLoopSource(port),
                               kCFRunLoopDefaultMode);
            NSLog(@"[TBHelper] power notifications registered");
        } else {
            NSLog(@"[TBHelper] WARNING: IORegisterForSystemPower failed; wake reapply disabled");
        }

        // 3. Boot restore (slight delay: kext subsystem may not be ready at earliest boot)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [helper restoreStateAtBoot];
        });

        [[NSRunLoop currentRunLoop] run];
    }
    return 0; // never reached
}
