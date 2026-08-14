#import "LSSLocSimController.h"
#import "CLSimulationManager.h"
#import "LSSLogger.h"
#include <sys/sysctl.h>

// locationd holds the simulation session; if it restarts, our session dies
// silently. Returns locationd's current pid, or -1 if not found.
// KERN_PROC_ALL scan, ~one call per push. Fine at push rates.
static pid_t locationd_pid(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return -1;

    struct kinfo_proc *procs = malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return -1; }

    pid_t found = -1;
    size_t n = len / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "locationd") == 0) {
            found = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return found;
}

static void post_required_timezone_update(void) {
    CFNotificationCenterPostNotificationWithOptions(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("AutomaticTimeZoneUpdateNeeded"),
        NULL,
        NULL,
        kCFNotificationDeliverImmediately
    );
}

@interface LSSLocSimController ()
@property(nonatomic, strong) CLSimulationManager *sim;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, assign) pid_t sessionLocationdPID;
@property(nonatomic, strong) dispatch_queue_t q;
@end

@implementation LSSLocSimController
+ (instancetype)shared {
    static LSSLocSimController *g;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g = [[LSSLocSimController alloc] init];
    });
    return g;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("LocationSpoofServer.locsim", DISPATCH_QUEUE_SERIAL);
        _sim = [[CLSimulationManager alloc] init];
        _sim.locationRepeatBehavior = 1;
        _started = NO;
    }
    return self;
}

- (void)log:(NSString *)line {
    [[LSSLogger shared] log:line tag:@"LOCSIM"];
}

// Must run on self.q. (Re-)opens the sim session against whatever locationd
// is running now. Idempotent-safe: also called when locationd's pid changes.
- (void)_establish {
    [self.sim stopLocationSimulation];
    [self.sim clearSimulatedLocations];
    [self.sim flush];
    [self.sim startLocationSimulation];

    self.started = YES;
    self.sessionLocationdPID = locationd_pid();
    post_required_timezone_update();
    [self log:[NSString stringWithFormat:@"session established (locationd pid %d)", self.sessionLocationdPID]];
}

// Must run on self.q. Re-establish if we never started or locationd restarted.
- (void)_ensureSessionLive {
    pid_t now = locationd_pid();
    if (!self.started || (now > 0 && now != self.sessionLocationdPID)) {
        if (self.started) {
            [self log:[NSString stringWithFormat:@"locationd restarted (%d -> %d), re-arming", self.sessionLocationdPID, now]];
        }
        [self _establish];
    }
}

- (void)start {
    dispatch_async(self.q, ^{
        [self _establish];
    });
}

- (void)stop {
    dispatch_async(self.q, ^{
        [self.sim stopLocationSimulation];
        [self.sim clearSimulatedLocations];
        [self.sim flush];
        self.started = NO;
        post_required_timezone_update();
        [self log:@"simulation stopped"];
    });
}

- (void)pushLocation:(CLLocation *)loc {
    if (!loc) return;

    dispatch_async(self.q, ^{
        [self _ensureSessionLive];

        [self.sim appendSimulatedLocation:loc];
        [self.sim flush];

        CLLocationCoordinate2D c = loc.coordinate;
        [self log:[NSString stringWithFormat:@"push lat=%.6f lon=%.6f", c.latitude, c.longitude]];
    });
}
@end
