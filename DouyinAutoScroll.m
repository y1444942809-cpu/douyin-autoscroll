//
//  DouyinAutoScrollV2.m
//  抖音播放完毕自动上滑 —— 重写版
//
//  V1 失效的两个根本原因：
//   1) DYOnMainFeed 依赖 DYTopViewController 沿 UITabBarController 找顶层 VC，
//      而抖音用的是自研 TabBar（AWENormalModeTabBar : UIView），
//      顶层 VC 名字不含 Feed/AwemeDetail → 判断永远 NO → 检测逻辑整个被跳过。
//   2) AWEFeedTableView 在抖音头文件里是 UIView 子类，不是 UIScrollView，
//      直接改 contentOffset 很可能不触发抖音自己的翻页逻辑。
//
//  V2 对策：
//   - 去掉脆弱的 VC 类名判断，改为"App 在前台 + 有全屏视频视图"即工作。
//   - 主动模拟真实的"上滑手势"（UITouch + UIEvent + sendEvent），
//     让抖音自己的手势识别器翻页，而不是硬改 contentOffset。
//   - 若手势未翻页，再回退到 contentOffset / scrollToItem。
//   - 内置诊断面板：长按左上角开关 1 秒弹出，可看到每一步状态。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - 可调参数

static const NSTimeInterval kEndTolerance   = 0.40;   // 距结尾多少秒算播完
static const NSTimeInterval kScrollCooldown = 1.50;   // 两次上滑最小间隔
static const NSTimeInterval kPollInterval   = 0.20;   // 轮询周期
static NSString *const kEnabledKey = @"com.douyin.autoscroll.enabled";
static const NSInteger kSwitchTag = 887712;

#pragma mark - 诊断计数

static int gHookOK      = 0;   // 进度回调 Hook 是否装上
static int gNotifCount  = 0;   // 收到 AVPlayerItem 结束通知次数
static int gPollHit     = 0;   // 轮询判定播完次数
static int gEndCount    = 0;   // videoReachedEnd 调用次数
static int gSwipeCount  = 0;   // 模拟上滑执行次数
static int gFallback    = 0;   // contentOffset 兜底次数
static NSString *gLastVC    = @"-";
static NSString *gLastView  = @"-";
static NSDate   *gLastFire  = nil;
static double    gTimeAtFire = -1.0;
static double    gLastCur    = -1.0;  // 进度回调最后一次的 current 参数
static double    gLastDur    = -1.0;  // 进度回调最后一次的 duration 参数
static int       gProgressCalls = 0;  // 进度回调被调用总次数

#pragma mark - 工具函数

static BOOL DYIsTargetApp(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bid rangeOfString:@"Aweme"].location != NSNotFound;
}

static UIViewController *DYTopViewController(void) {
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UITabBarController class]] && [(UITabBarController *)vc selectedViewController]) {
        vc = [(UITabBarController *)vc selectedViewController];
    }
    if ([vc isKindOfClass:[UINavigationController class]] && [(UINavigationController *)vc topViewController]) {
        vc = [(UINavigationController *)vc topViewController];
    }
    return vc;
}

static void DYCollectPlayerLayers(CALayer *layer, NSMutableArray<AVPlayerLayer *> *out) {
    if ([layer isKindOfClass:[AVPlayerLayer class]]) [out addObject:(AVPlayerLayer *)layer];
    for (CALayer *sub in layer.sublayers) DYCollectPlayerLayers(sub, out);
}

static AVPlayer *DYActivePlayer(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return nil;
    NSMutableArray<AVPlayerLayer *> *layers = [NSMutableArray array];
    DYCollectPlayerLayers(win.layer, layers);
    AVPlayer *candidate = nil;
    for (AVPlayerLayer *pl in layers) {
        AVPlayer *p = pl.player;
        if (!p || !p.currentItem) continue;
        if (p.rate > 0.0) return p;                 // 正在播放的就是它
        if (!candidate && CMTimeGetSeconds(p.currentTime) > 0.5) candidate = p;
    }
    return candidate;
}

static void DYCollectFullscreenScrollViews(UIView *view, NSMutableArray<UIScrollView *> *out) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        if (sv.bounds.size.height >= screenH * 0.70 &&
            sv.contentSize.height > sv.bounds.size.height + 2.0) {
            [out addObject:sv];
        }
    }
    for (UIView *sub in view.subviews) DYCollectFullscreenScrollViews(sub, out);
}

#pragma mark - 模拟真实上滑手势

static void DYSimulateSwipeUp(UIView *view) {
    if (!view || !view.window) return;

    CGFloat w = view.bounds.size.width;
    CGFloat h = view.bounds.size.height;
    CGFloat cx = w / 2.0;

    // 从屏幕中下部滑到中上部 —— 视频画面区域，避开右侧点赞栏和顶部标题
    NSArray *points = @[
        [NSValue valueWithCGPoint:CGPointMake(cx, h * 0.76)],
        [NSValue valueWithCGPoint:CGPointMake(cx, h * 0.68)],
        [NSValue valueWithCGPoint:CGPointMake(cx, h * 0.58)],
        [NSValue valueWithCGPoint:CGPointMake(cx, h * 0.46)],
        [NSValue valueWithCGPoint:CGPointMake(cx, h * 0.34)],
        [NSValue valueWithCGPoint:CGPointMake(cx, h * 0.28)]
    ];
    // UITouchPhase: Began=0, Moved=1, Stationary=2, Ended=3, Cancelled=4
    NSArray *phases = @[@0, @1, @1, @1, @1, @3];

    NSTimeInterval base = [[NSDate date] timeIntervalSince1970];

    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:view forKey:@"_view"];
    [touch setValue:view.window forKey:@"_window"];
    [touch setValue:@(0) forKey:@"_tapCount"];
    [touch setValue:@(1.0) forKey:@"_force"];
    [touch setValue:@(base) forKey:@"_timestamp"];

    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:@(0) forKey:@"_type"];                       // UIEventTypeTouches
    [event setValue:[NSSet setWithObject:touch] forKey:@"_touches"];
    [event setValue:@(base) forKey:@"_timestamp"];

    for (NSUInteger i = 0; i < points.count; i++) {
        CGPoint p = [(NSValue *)points[i] CGPointValue];
        CGPoint prev = [(NSValue *)points[i == 0 ? 0 : i - 1] CGPointValue];
        NSNumber *phase = phases[i];
        NSTimeInterval ts = base + i * 0.02;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.02 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [touch setValue:phase forKey:@"_phase"];
            [touch setValue:[NSValue valueWithCGPoint:p] forKey:@"_locationInWindow"];
            [touch setValue:[NSValue valueWithCGPoint:prev] forKey:@"_previousLocationInWindow"];
            [touch setValue:@(ts) forKey:@"_timestamp"];
            [[UIApplication sharedApplication] sendEvent:event];
        });
    }
    gSwipeCount++;
}

#pragma mark - Manager 声明

@interface DYAutoScrollManager : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL armed;
@property (nonatomic, assign) NSTimeInterval lastTrigger;
@property (nonatomic, strong) NSTimer *pollTimer;
- (void)start;
- (void)installHooks;
- (void)videoReachedEnd;
- (void)ensureSwitchButton;
@end

#pragma mark - 进度回调 Hook

static IMP gOriginalProgressIMP = NULL;
static BOOL gProgressHooked = NO;

static void DYProgressHook(id self, SEL _cmd, double currentTime, double totalDuration) {
    gLastCur = currentTime;
    gLastDur = totalDuration;
    gProgressCalls++;
    if (gOriginalProgressIMP) {
        ((void (*)(id, SEL, double, double))gOriginalProgressIMP)(self, _cmd, currentTime, totalDuration);
    }
    DYAutoScrollManager *m = [DYAutoScrollManager sharedInstance];

    // 兼容三种可能的参数语义：秒、毫秒、0~1 比例
    BOOL nearEnd = NO;
    if (totalDuration > 1.5 && currentTime >= totalDuration - kEndTolerance) {
        nearEnd = YES;                                  // 秒
    } else if (totalDuration > 1000.0 && currentTime >= totalDuration - 400.0) {
        nearEnd = YES;                                  // 毫秒
    } else if (currentTime >= 0.97 && currentTime <= 1.5 && totalDuration <= 1.5) {
        nearEnd = YES;                                  // 0~1 比例
    }

    // 时间看起来"回到开头"就重新武装（同样兼容三种单位）
    if (currentTime < 1.0 || currentTime < totalDuration * 0.05) m.armed = YES;

    if (m.armed && nearEnd) {
        m.armed = NO;
        [m videoReachedEnd];
    }
}

#pragma mark - Manager 实现

@implementation DYAutoScrollManager

+ (instancetype)sharedInstance {
    static DYAutoScrollManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _armed = YES;
        BOOL state = YES;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        id stored = [ud objectForKey:kEnabledKey];
        if (stored) state = [stored boolValue];
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/DouyinAutoScroll.plist"];
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([cfg objectForKey:@"Enabled"]) state = [cfg[@"Enabled"] boolValue];
        _enabled = state;
    }
    return self;
}

- (void)start {
    [self installHooks];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(handleItemEnd:)
               name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [nc addObserver:self selector:@selector(appActive:)
               name:UIApplicationDidBecomeActiveNotification object:nil];

    if (!self.pollTimer) {
        self.pollTimer = [NSTimer timerWithTimeInterval:kPollInterval target:self
                                              selector:@selector(poll:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
    }
    [self ensureSwitchButton];
    // keyWindow 在某些时机还没就绪，补一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self ensureSwitchButton]; });
}

- (void)installHooks {
    if (gProgressHooked) return;
    Class cls = objc_getClass("AWEPlayInteractionProgressController");
    if (!cls) return;
    SEL sel = sel_registerName("updateProgressSliderWithTime:totalDuration:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    char *a2 = method_copyArgumentType(method, 2);
    char *a3 = method_copyArgumentType(method, 3);
    BOOL ok = (a2 && a3 && a2[0] == 'd' && a3[0] == 'd');
    free(a2); free(a3);
    if (!ok) return;

    IMP original = method_getImplementation(method);
    if (!original) return;
    class_replaceMethod(cls, sel, (IMP)DYProgressHook, method_getTypeEncoding(method));
    gOriginalProgressIMP = original;
    gProgressHooked = YES;
    gHookOK = 1;
}

- (void)appActive:(NSNotification *)note {
    [self installHooks];
    [self ensureSwitchButton];
}

- (void)handleItemEnd:(NSNotification *)note {
    gNotifCount++;
    if (!self.enabled) return;
    self.armed = NO;
    [self videoReachedEnd];
}

- (void)poll:(NSTimer *)timer {
    UIViewController *vc = DYTopViewController();
    gLastVC = NSStringFromClass([vc class]) ?: @"?";

    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (win) {
        NSMutableArray<UIScrollView *> *svs = [NSMutableArray array];
        DYCollectFullscreenScrollViews(win, svs);
        gLastView = [NSString stringWithFormat:@"%lu 个全屏滚动容器", (unsigned long)svs.count];
    }

    if (!self.enabled || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;

    AVPlayer *player = DYActivePlayer();
    if (!player) return;
    CMTime ct = player.currentTime;
    CMTime dt = player.currentItem.duration;
    if (!CMTIME_IS_VALID(ct) || !CMTIME_IS_VALID(dt)) return;

    double t = CMTimeGetSeconds(ct);
    double d = CMTimeGetSeconds(dt);
    if (isnan(t) || isnan(d)) return;

    if (t < 1.0) self.armed = YES;
    if (self.armed && d > 0.5 && t >= d - kEndTolerance) {
        self.armed = NO;
        gPollHit++;
        [self videoReachedEnd];
    }
}

- (void)videoReachedEnd {
    if (!self.enabled) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastTrigger < kScrollCooldown) return;
    self.lastTrigger = now;
    gEndCount++;
    gLastFire = [NSDate date];

    AVPlayer *p = DYActivePlayer();
    gTimeAtFire = p ? CMTimeGetSeconds(p.currentTime) : -1.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self doScroll];
    });
}

- (void)doScroll {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;

    // 主方案：模拟真实上滑手势，交给抖音自己的手势识别器处理
    UIView *target = DYTopViewController().view ?: win;
    DYSimulateSwipeUp(target);

    // 兜底：0.45 秒后如果播放时间没变（说明没翻页），改用 contentOffset
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AVPlayer *p2 = DYActivePlayer();
        double t2 = p2 ? CMTimeGetSeconds(p2.currentTime) : -1.0;
        if (gTimeAtFire >= 0 && t2 >= 0 && fabs(t2 - gTimeAtFire) < 1.0) {
            [self scrollViaContentOffset];
        }
    });
}

- (void)scrollViaContentOffset {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    NSMutableArray<UIScrollView *> *svs = [NSMutableArray array];
    DYCollectFullscreenScrollViews(win, svs);
    if (svs.count == 0) return;

    UIScrollView *sv = nil;
    for (UIScrollView *c in svs) {
        if ([c isKindOfClass:[UICollectionView class]]) { sv = c; break; }
    }
    if (!sv) sv = svs.firstObject;

    CGFloat page = sv.bounds.size.height;
    CGFloat maxY = sv.contentSize.height - sv.bounds.size.height;
    CGFloat targetY = MIN(sv.contentOffset.y + page, maxY);
    if (targetY > sv.contentOffset.y + 2.0) {
        [sv setContentOffset:CGPointMake(sv.contentOffset.x, targetY) animated:YES];
        gFallback++;
    }
}

#pragma mark - 开关 + 诊断面板

- (void)ensureSwitchButton {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;

    UIButton *btn = (UIButton *)[win viewWithTag:kSwitchTag];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = kSwitchTag;
        btn.layer.cornerRadius = 15.0;
        btn.layer.masksToBounds = YES;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(toggleSwitch) forControlEvents:UIControlEventTouchUpInside];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                            initWithTarget:self action:@selector(showDiagnostics:)];
        lp.minimumPressDuration = 1.0;
        [btn addGestureRecognizer:lp];
        [win addSubview:btn];
    }

    btn.frame = CGRectMake(10.0, win.safeAreaInsets.top + 8.0, 82.0, 30.0);
    if (self.enabled) {
        [btn setTitle:@"自动滑 ▮" forState:UIControlStateNormal];
        btn.backgroundColor = [[UIColor colorWithRed:0.10 green:0.72 blue:0.36 alpha:1.0]
                               colorWithAlphaComponent:0.72];
    } else {
        [btn setTitle:@"自动滑 ○" forState:UIControlStateNormal];
        btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.50];
    }
    [win bringSubviewToFront:btn];
}

- (void)toggleSwitch {
    self.enabled = !self.enabled;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:self.enabled forKey:kEnabledKey];
    [ud synchronize];
    self.armed = YES;
    [self ensureSwitchButton];
    [self showToast:self.enabled ? @"自动上滑：已开启" : @"自动上滑：已关闭"];
}

- (void)showDiagnostics:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    NSString *age = gLastFire ? [NSString stringWithFormat:@"%.0f 秒前",
                                  -[gLastFire timeIntervalSinceNow]] : @"从未";
    NSString *msg = [NSString stringWithFormat:
        @"Bundle：%@\n"
        "开关：%@\n"
        "进度Hook：%@（调用 %d 次）\n"
        "最后进度：cur=%.2f dur=%.2f\n"
        "结束通知：%d 次\n"
        "轮询命中：%d 次\n"
        "触发上滑：%d 次\n"
        "模拟手势：%d 次\n"
        "兜底滚动：%d 次\n"
        "当前页面：%@\n"
        "容器：%@\n"
        "上次触发：%@",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
        self.enabled ? @"开" : @"关",
        gHookOK ? @"成功" : @"未装上", gProgressCalls,
        gLastCur, gLastDur,
        gNotifCount, gPollHit, gEndCount, gSwipeCount, gFallback,
        gLastVC, gLastView, age];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自动滑 · 诊断"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"测试手动上滑" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        // 延迟 1 秒等弹窗关闭后执行，直接验证手势翻页是否管用
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self doScroll];
        });
    }]];
    UIViewController *top = DYTopViewController();
    if (top.presentedViewController == nil) {
        [top presentViewController:ac animated:YES completion:nil];
    }
}

- (void)showToast:(NSString *)text {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
    label.font = [UIFont systemFontOfSize:14.0];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 8.0;
    label.layer.masksToBounds = YES;
    CGSize fit = [label sizeThatFits:CGSizeMake(280.0, 44.0)];
    label.frame = CGRectMake((win.bounds.size.width - fit.width - 24.0) / 2.0,
                             win.bounds.size.height * 0.72, fit.width + 24.0, fit.height + 16.0);
    label.alpha = 0.0;
    [win addSubview:label];
    [win bringSubviewToFront:label];
    [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1.0; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.25 delay:1.2 options:0 animations:^{ label.alpha = 0.0; }
                         completion:^(BOOL d) { [label removeFromSuperview]; }];
    }];
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void DYAutoScrollInit(void) {
    if (!DYIsTargetApp()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DYAutoScrollManager sharedInstance] start];
    });
}
