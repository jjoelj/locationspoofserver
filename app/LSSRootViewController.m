#import "LSSRootViewController.h"
#import "LSSDaemonClient.h"
#import "LSSLogger.h"
#import "LSSQRGen.h"
#import <CoreGraphics/CoreGraphics.h>

// Render a QR for `string` with CoreGraphics. CoreImage's CIQRCodeGenerator
// segfaults on this device, so we encode the matrix ourselves (LSSQRGen) and
// fill black squares into a bitmap context.
static UIImage *QRImage(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t modules[37 * 37]; // v5 max, matches LSSQRGen's ceiling
    int N = lss_qr_encode(data.bytes, (int)data.length, modules);
    if (N == 0) return nil;

    const int scale = 12, quiet = 4;
    int px = (N + 2 * quiet) * scale;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, px, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    CGContextSetGrayFillColor(ctx, 1.0, 1.0); CGContextFillRect(ctx, CGRectMake(0, 0, px, px)); // white
    CGContextSetGrayFillColor(ctx, 0.0, 1.0); // black modules
    for (int r = 0; r < N; r++)
        for (int c = 0; c < N; c++)
            if (modules[r * N + c]) {
                int x = (quiet + c) * scale;
                int y = (quiet + (N - 1 - r)) * scale; // CG origin is bottom-left
                CGContextFillRect(ctx, CGRectMake(x, y, scale, scale));
            }

    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

@interface LSSRootViewController ()
@property(nonatomic, strong) LSSDaemonClient *daemon;

@property(nonatomic, strong) UITextView *serverLogView;
@property(nonatomic, strong) UITextView *logView;

@property(nonatomic, strong) UILabel *tokenCaption;
@property(nonatomic, strong) UILabel *tokenLabel;
@property(nonatomic, strong) UIButton *tokenEyeBtn;
@property(nonatomic, strong) UIButton *urlEyeBtn;
@property(nonatomic, strong) UIActivityIndicatorView *loginSpinner;
@property(nonatomic, strong) UIButton *tailscaleBtn;
@property(nonatomic, strong) UIStackView *tokenActions;
@property(nonatomic, strong) UIStackView *serverActions;
@property(nonatomic, strong) UILabel *urlCaption;
@property(nonatomic, strong) UILabel *statusCaption;
@property(nonatomic, strong) UILabel *serverLogCaption;
@property(nonatomic, strong) UILabel *logCaption;
@property(nonatomic, strong) UILabel *urlLabel;
@property(nonatomic, strong) UIStackView *statusRow;
@property(nonatomic, strong) NSDictionary<NSString *, UILabel *> *statusLabels;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *publicURL;
@property(nonatomic, assign) BOOL tokenHidden;
@property(nonatomic, assign) BOOL urlHidden;
@property(nonatomic, assign) BOOL loginInFlight;
@property(nonatomic, strong) UIImage *qrCache; // built once; math is not free
@property(nonatomic, copy) NSString *serverLogRaw; // uncensored; masked at render

@property(nonatomic, strong) NSTimer *logTimer;
@end

@implementation LSSRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.daemon = [[LSSDaemonClient alloc] init];
    self.tokenHidden = YES;
    self.urlHidden = YES;

    [self buildUI];
    [self startLogPolling];
    [self fetchToken];
}

- (void)fetchToken {
    __weak typeof(self) weakSelf = self;
    [self.daemon getToken:^(BOOL ok, NSString *token, NSString *url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.token = (ok && token.length) ? token : nil;
            weakSelf.publicURL = (ok && url.length) ? url : nil;
            weakSelf.qrCache = nil; // token changed, drop cached image
            [weakSelf updateTokenDisplay];
            [weakSelf updateURLDisplay];
        });
    }];
}

// The URL is not a secret the way the token is -- every endpoint but / still
// needs the token -- but it names the device on the public internet, so it is
// masked by default and revealed on request. Screenshots stay postable.
- (void)updateURLDisplay {
    BOOL connected = self.publicURL.length > 0;
    if (connected) {
        self.urlLabel.text = self.urlHidden ? @"••••••••••••••••••••" : self.publicURL;
        self.urlLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        self.urlLabel.text = @"Tailscale not connected";
        self.urlLabel.textColor = [UIColor systemOrangeColor];
    }
    [self.urlEyeBtn setTitle:(self.urlHidden ? @"Show URL" : @"Hide URL") forState:UIControlStateNormal];
    self.urlEyeBtn.enabled = connected;

    // One button, three states: logging in, or whichever of log in / log out
    // makes sense once we know. The poll timer calls through here every half
    // second, so the in-flight title has to be reasserted, not set once.
    NSString *title = self.loginInFlight ? @"Contacting…"
                                         : (connected ? @"Log out of Tailscale" : @"Log in to Tailscale");
    [self.tailscaleBtn setTitle:title forState:UIControlStateNormal];
    self.tailscaleBtn.enabled = !self.loginInFlight;
    self.tailscaleBtn.tintColor = connected ? [UIColor systemRedColor] : [UIColor systemBlueColor];
    if (self.loginInFlight) [self.loginSpinner startAnimating]; else [self.loginSpinner stopAnimating];
}

- (void)toggleURLVisibility {
    self.urlHidden = !self.urlHidden;
    [self updateURLDisplay];
    [self refreshLogViews];
}

- (void)tapURL {
    if (self.publicURL.length == 0) return;
    [UIPasteboard generalPasteboard].string = self.publicURL;
    [self log:@"public url copied"];
}

- (void)tapTailscale {
    if (self.publicURL.length == 0) {
        [self loginToTailscale];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Log out of Tailscale?"
                                                                  message:@"The public URL stops working until you log in again from this app."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Log Out" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [weakSelf.daemon tailscaleLogout:^(BOOL ok, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf log:ok ? @"logged out of tailscale"
                                 : [NSString stringWithFormat:@"logout failed: %@", message]];
                [weakSelf fetchToken];
            });
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// The daemon runs `tailscale up` and we hand its login page to Safari. The
// poll timer picks up the public URL once the login goes through.
- (void)loginToTailscale {
    [self log:@"asking tailscale for a login link…"];
    self.loginInFlight = YES;   // `tailscale up` can sit there for seconds
    [self updateURLDisplay];

    __weak typeof(self) weakSelf = self;
    [self.daemon tailscaleLogin:^(BOOL ok, NSString *loginURL, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.loginInFlight = NO;
            [weakSelf updateURLDisplay];
            if (!ok) {
                [weakSelf log:[NSString stringWithFormat:@"tailscale login failed: %@", message]];
                return;
            }
            if (loginURL.length == 0) {
                [weakSelf log:@"tailscale already logged in"];
                [weakSelf fetchToken];
                return;
            }
            [weakSelf log:@"opening tailscale login in Safari…"];
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:loginURL]
                                               options:@{}
                                     completionHandler:nil];
        });
    }];
}

// Bullets when hidden, the value when revealed; keeps the eye icon in sync.
- (void)updateTokenDisplay {
    if (self.token.length == 0) {
        self.tokenLabel.text = @"(unavailable)";
    } else if (self.tokenHidden) {
        NSUInteger keep = MIN((NSUInteger)4, self.token.length);
        self.tokenLabel.text = [@"••••••••" stringByAppendingString:[self.token substringFromIndex:self.token.length - keep]];
    } else {
        self.tokenLabel.text = self.token;
    }
    [self.tokenEyeBtn setTitle:(self.tokenHidden ? @"Show" : @"Hide") forState:UIControlStateNormal];
}

- (void)toggleTokenVisibility {
    self.tokenHidden = !self.tokenHidden;
    [self updateTokenDisplay];
    [self refreshLogViews];
}

- (void)regenerateToken {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Regenerate Token?"
                                                                   message:@"Clients using the current token will stop working."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Regenerate" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [weakSelf.daemon regenerateToken:^(BOOL ok, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    [weakSelf log:@"token regenerated"];
                    [weakSelf fetchToken];
                } else {
                    [weakSelf log:[NSString stringWithFormat:@"regenerate failed: %@", message]];
                }
            });
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restartDaemon {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Server?"
                                                                  message:@"Location spoofing stops until it comes back, a second or two later."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf log:@"restarting server…"];
        [weakSelf.daemon restartDaemon:^(BOOL ok, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) {
                    [weakSelf log:[NSString stringWithFormat:@"restart failed: %@", message]];
                    return;
                }
                // launchd needs a moment to notice and respawn before we can ask
                // it anything; the re-fetch is also how the URL gets refreshed.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [weakSelf log:@"server restarted"];
                    [weakSelf fetchToken];
                });
            });
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// One scan gives a client both where to reach us and the token to do it with.
// Falls back to the bare token when Tailscale has not come up yet.
- (NSString *)qrPayload {
    if (self.publicURL.length == 0) return self.token;
    return [NSString stringWithFormat:@"%@/?token=%@", self.publicURL, self.token];
}

- (void)showQR {
    if (self.token.length == 0) return;
    if (!self.qrCache) self.qrCache = QRImage([self qrPayload]); // cache: encode once
    UIImage *img = self.qrCache;
    if (!img) return;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.layer.magnificationFilter = kCAFilterNearest; // keep QR pixels crisp
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *hint = [[UILabel alloc] init];
    hint.text = self.publicURL.length
        ? [NSString stringWithFormat:@"%@ · tap to dismiss", self.publicURL]
        : @"Token only — Tailscale not connected · tap to dismiss";
    hint.font = [UIFont systemFontOfSize:14];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    [vc.view addSubview:iv];
    [vc.view addSubview:hint];
    UILayoutGuide *g = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [iv.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [iv.widthAnchor constraintEqualToAnchor:g.widthAnchor multiplier:0.8],
        [iv.heightAnchor constraintEqualToAnchor:iv.widthAnchor],
        [hint.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:16],
        [hint.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    ]];

    [vc.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissQR)]];
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)dismissQR {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [self.logTimer invalidate];
    self.logTimer = nil;
}

#pragma mark - UI

// Words, not glyphs: an eye or a pencil is a guessing game, "Show" and
// "Regenerate" are not. Titles shrink rather than truncate on narrow screens.
- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    b.contentEdgeInsets = UIEdgeInsetsMake(9, 6, 9, 6);
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor systemGray4Color].CGColor;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIStackView *)makeButtonRow:(NSArray<UIButton *> *)buttons {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    // Buttons hug like a text view does by default; without this the vertical
    // stack grows the button rows instead of the log panes.
    [row setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    return row;
}

- (UILabel *)makeCaption:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    l.textColor = [UIColor tertiaryLabelColor];
    l.text = text;
    return l;
}

- (void)buildUI {
    self.tokenCaption = [self makeCaption:@"TOKEN"];

    self.tokenLabel = [[UILabel alloc] init];
    self.tokenLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.tokenLabel.textColor = [UIColor secondaryLabelColor];
    self.tokenLabel.adjustsFontSizeToFitWidth = YES;
    self.tokenLabel.minimumScaleFactor = 0.6;
    self.tokenLabel.text = @"loading token…";

    self.tokenEyeBtn = [self makeButton:@"Show" action:@selector(toggleTokenVisibility)];
    self.tokenActions = [self makeButtonRow:@[
        self.tokenEyeBtn,
        [self makeButton:@"Regenerate" action:@selector(regenerateToken)],
        [self makeButton:@"QR code" action:@selector(showQR)],
    ]];

    self.urlCaption = [self makeCaption:@"PUBLIC URL — TAP TO COPY"];

    self.urlLabel = [[UILabel alloc] init];
    self.urlLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.urlLabel.textColor = [UIColor secondaryLabelColor];
    self.urlLabel.adjustsFontSizeToFitWidth = YES;
    self.urlLabel.minimumScaleFactor = 0.6;
    self.urlLabel.text = @"…";
    self.urlLabel.userInteractionEnabled = YES;
    [self.urlLabel addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapURL)]];

    // One dot per daemon: green up, red down, grey not asked yet. Unknown until
    // the first poll answers, so nothing claims to be up before we have asked.
    self.statusCaption = [self makeCaption:@"DAEMONS"];
    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    NSMutableArray *arranged = [NSMutableArray array];
    for (NSString *name in @[@"locationspoofd", @"fmfwatchd", @"tailscaled"]) {
        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        l.textColor = [UIColor tertiaryLabelColor];
        l.text = [NSString stringWithFormat:@"● %@", name];
        labels[name] = l;
        [arranged addObject:l];
    }
    self.statusLabels = labels;
    self.statusRow = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    self.statusRow.axis = UILayoutConstraintAxisHorizontal;
    self.statusRow.distribution = UIStackViewDistributionFillProportionally;
    self.statusRow.spacing = 10;
    [self.statusRow setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    self.urlEyeBtn = [self makeButton:@"Show URL" action:@selector(toggleURLVisibility)];
    self.tailscaleBtn = [self makeButton:@"Log in to Tailscale" action:@selector(tapTailscale)];

    // Rides on the button it describes, so there is no row to make space for.
    self.loginSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loginSpinner.hidesWhenStopped = YES;
    self.loginSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tailscaleBtn addSubview:self.loginSpinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.loginSpinner.trailingAnchor constraintEqualToAnchor:self.tailscaleBtn.trailingAnchor constant:-8],
        [self.loginSpinner.centerYAnchor constraintEqualToAnchor:self.tailscaleBtn.centerYAnchor],
    ]];
    self.serverActions = [self makeButtonRow:@[
        self.urlEyeBtn,
        [self makeButton:@"Restart server" action:@selector(restartDaemon)],
        self.tailscaleBtn,
    ]];

    self.serverLogCaption = [self makeCaption:@"SERVER LOG"];
    self.serverLogView = [[UITextView alloc] init];
    self.serverLogView.editable = NO;
    self.serverLogView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.serverLogView.layer.cornerRadius = 12;
    self.serverLogView.layer.borderWidth = 1.0;
    self.serverLogView.layer.borderColor = [UIColor systemGray4Color].CGColor;

    self.logCaption = [self makeCaption:@"APP LOG"];
    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.layer.cornerRadius = 12;
    self.logView.layer.borderWidth = 1.0;
    self.logView.layer.borderColor = [UIColor systemGray4Color].CGColor;

    // One vertical stack, top to bottom: token, public URL, server actions,
    // daemon dots, then the two log panes. Spacing comes from the stack, so
    // there is nothing to re-pin when a row moves.
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.tokenCaption, self.tokenLabel, self.tokenActions,
        self.urlCaption, self.urlLabel,
        self.serverActions,
        self.statusCaption, self.statusRow,
        self.serverLogCaption, self.serverLogView,
        self.logCaption, self.logView,
    ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 6;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    // Extra air before each caption, so the sections read as sections.
    [column setCustomSpacing:18 afterView:self.tokenActions];
    [column setCustomSpacing:12 afterView:self.urlLabel];
    [column setCustomSpacing:18 afterView:self.serverActions];
    [column setCustomSpacing:18 afterView:self.statusRow];
    [column setCustomSpacing:14 afterView:self.serverLogView];

    [self.view addSubview:column];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [column.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [column.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [column.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],

        [self.serverLogView.heightAnchor constraintEqualToAnchor:self.logView.heightAnchor],
        [self.serverLogView.heightAnchor constraintGreaterThanOrEqualToConstant:100],
    ]];
}

#pragma mark - Log helpers

// The daemon logs the public URL when it comes up, and any leak of the token
// would land here too. Masking at render, not at write, keeps the log file on
// the device complete while a screenshot of this screen stays postable: what
// the labels above hide, the panes below hide as well.
- (NSString *)censor:(NSString *)text {
    if (self.urlHidden && self.publicURL.length)
        text = [text stringByReplacingOccurrencesOfString:self.publicURL withString:@"••••••••"];
    if (self.tokenHidden && self.token.length)
        text = [text stringByReplacingOccurrencesOfString:self.token withString:@"••••••••"];
    return text;
}

- (void)setLogText:(NSString *)text inView:(UITextView *)view {
    view.text = [self censor:text ?: @""];
    if (view.text.length == 0) return;
    [view scrollRangeToVisible:NSMakeRange(view.text.length - 1, 1)];
}

// Both panes, re-rendered from what we last had. Called when a Show/Hide
// toggle flips, so the masking changes the moment the label does.
- (void)refreshLogViews {
    [self setLogText:[[LSSLogger shared] snapshot] inView:self.logView];
    [self setLogText:self.serverLogRaw inView:self.serverLogView];
}

- (void)log:(NSString *)line {
    [[LSSLogger shared] log:line tag:@"UI"];
    [self setLogText:[[LSSLogger shared] snapshot] inView:self.logView];
}

// Green when up, red when down, grey when we could not ask at all -- which is
// itself the answer for locationspoofd, since it serves this very endpoint.
- (void)refreshStatus {
    __weak typeof(self) weakSelf = self;
    [self.daemon getStatus:^(BOOL ok, NSDictionary *daemons) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.statusLabels enumerateKeysAndObjectsUsingBlock:^(NSString *name, UILabel *l, __unused BOOL *stop) {
                if (!ok) {
                    l.textColor = [UIColor tertiaryLabelColor];
                    return;
                }
                BOOL up = [daemons[name] boolValue];
                l.textColor = up ? [UIColor systemGreenColor] : [UIColor systemRedColor];
            }];
        });
    }];
}

- (void)startLogPolling {
    __weak typeof(self) weakSelf = self;
    [self.daemon getLogs:^(BOOL ok, NSString *logs) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) return;
            weakSelf.serverLogRaw = logs;
            [weakSelf setLogText:logs inView:weakSelf.serverLogView];
            [weakSelf log:@"log polling started"];
        });
    }];

    [self refreshStatus];

    __block int tick = 0;
    self.logTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *t) {
        // Daemon may start after us; the URL also shows up late, once a login lands.
        if (weakSelf.token.length == 0 || weakSelf.publicURL.length == 0) [weakSelf fetchToken];
        if (++tick % 4 == 0) [weakSelf refreshStatus];         // liveness moves slower than logs
        [weakSelf.daemon getLogs:^(BOOL ok, NSString *logs) {
            if (!ok || !logs) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.serverLogRaw = logs;
                [weakSelf setLogText:logs inView:weakSelf.serverLogView];
            });
        }];
    }];
}

@end
