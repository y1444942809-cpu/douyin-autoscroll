//
//  DouyinAutoScroll V5 —— 观察进度条 UIView 判定播完
//
//  演进：
//   V1 检测 AVPlayer + 改 contentOffset   → 37.9.0 不走标准 AVPlayer，失败
//   V2 模拟上滑手势 sendEvent            → iOS15 伪造 UITouch 失效，失败
//   V3 强制打开原生"自动连播"开关        → 推荐页无此开关，失败
//   V4 Hook 进度方法 applyWidthPercent   → 37.9.0 无此方法，失败
//   V5 纯 UI 观察：定时扫描视图树里的进度条 UIView，
//      读它的宽度比例（含 frame/transform/CAShapeLayer.strokeEnd），
//      比例到顶即视为播完。翻页用已验证有效的 contentOffset 方案。
//
//  诊断面板：显示找到的进度视图数量、实时进度、视图类名和数值，
//            以及"测试上滑"按钮（已验证可用）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <stdarg.h>
#import <math.h>

#pragma mark - 配置

static NSString *const kEnabledKey = @"com.douyin.autoscroll.enabled";
static const NSInteger kSwitchTag = 887712;
static const NSTimeInterval kCooldown = 1.5;
static const NSTimeInterval kCheckInterval = 0.10;
static const double kEndThreshold = 0.96;   // 进度到多少算播完

#pragma mark - 全局状态

static BOOL gEnabled = YES;
static BOOL gArmed = YES;
static NSTimeInterval gLastFire = 0;
static double gLastPercent = -1.0;
static double gPrevPercent = -1.0;
static int gProgressViews = 0;
static int gScrollCount = 0;
static NSString *gProgressInfo = @"-";
static NSMutableArray<NSString *> *gEvents = nil;
static NSTimer *gCheckTimer = nil;

static void DYLog(NSString *fmt, ...) {
    if (!gEvents) return;
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [gEvents addObject:line];
    if (gEvents.count > 14) [gEvents removeObjectAtIndex:0];
}

#pragma mark - Manager 声明（定时器回调会用，必须先声明）

@interface DYAutoScrollManager : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)checkProgress:(NSTimer *)timer;
- (void)videoEnded;
- (void)performScroll;
- (void)ensureSwitchButton;
@end

#pragma mark - 工具

static BOOL DYIsTargetApp(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bid rangeOfString:@"Aweme"].location != NSNotFound;
}

static UIViewController *DYTopVC(void) {
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

// 递归收集名字里含 Progress/Slider 的视图
static void DYCollectProgressViews(UIView *view, NSMutableArray<UIView *> *out) {
    NSString *name = NSStringFromClass([view class]);
    if ([name rangeOfString:@"Progress"].location != NSNotFound ||
        [name rangeOfString:@"Slider"].location != NSNotFound) {
        [out addObject:view];
    }
    for (UIView *sub in view.subviews) DYCollectProgressViews(sub, out);
}

// 从进度条视图里读出 0~1 的进度值
static double DYReadProgress(UIView *slider) {
    double best = -1.0;
    CGFloat total = slider.bounds.size.width;

    // 1) 子视图里的填充条：宽度比例
    for (UIView *sub in slider.subviews) {
        CGFloat w = sub.frame.size.width;
        if (w > 0 && total > 0 && w <= total + 1.0) {
            double r = (double)w / (double)total;
            if (r > best) best = r;
        }
        // 2) transform.scale.x
        double sx = sub.transform.a;
        if (sx > 0 && sx <= 1.05 && sx > best) best = sx;
        // 3) CAShapeLayer.strokeEnd
        if ([sub.layer isKindOfClass:[CAShapeLayer class]]) {
            double se = ((CAShapeLayer *)sub.layer).strokeEnd;
            if (se > 0 && se <= 1.0 && se > best) best = se;
        }
    }
    // 4) 视图自身宽度相对父视图
    UIView *sup = slider.superview;
    if (best < 0 && sup && sup.bounds.size.width > 0 && total > 0) {
        double r = (double)total / (double)sup.bounds.size.width;
        if (r > 0 && r <= 1.05) best = r;
    }
    // 5) 视图自身 transform
    if (best < 0 && slider.transform.a > 0 && slider.transform.a <= 1.05) {
        best = slider.transform.a;
    }
    return best;
}

#pragma mark - Manager 实现

@implementation DYAutoScrollManager

+ (instancetype)sharedInstance {
    static DYAutoScrollManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        gEvents = [NSMutableArray array];
        gEnabled = YES;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        id stored = [ud objectForKey:kEnabledKey];
        if (stored) gEnabled = [stored boolValue];
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/DouyinAutoScroll.plist"];
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([cfg objectForKey:@"Enabled"]) gEnabled = [cfg[@"Enabled"] boolValue];
    }
    return self;
}

- (void)start {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    if (!gCheckTimer) {
        gCheckTimer = [NSTimer timerWithTimeInterval:kCheckInterval
                                             target:self
                                           selector:@selector(checkProgress:)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:gCheckTimer forMode:NSRunLoopCommonModes];
    }
    [self ensureSwitchButton];
    DYLog(@"启动完成");
}

- (void)appActive:(NSNotification *)note {
    [self ensureSwitchButton];
}

- (void)checkProgress:(NSTimer *)timer {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    DYCollectProgressViews(win, views);
    gProgressViews = (int)views.count;

    // 取所有候选里最大的进度值
    double maxP = -1.0;
    NSMutableArray<NSString *> *info = [NSMutableArray array];
    for (UIView *v in views) {
        double p = DYReadProgress(v);
        NSString *cls = NSStringFromClass([v class]);
        if (p >= 0) {
            [info addObject:[NSString stringWithFormat:@"%@:%.2f", cls, p]];
            if (p > maxP) maxP = p;
        } else {
            [info addObject:[NSString stringWithFormat:@"%@:?", cls]];
        }
    }
    gProgressInfo = info.count ? [info componentsJoinedByString:@" "] : @"未找到进度视图";

    if (maxP < 0) return;
    gPrevPercent = gLastPercent;
    gLastPercent = maxP;

    if (!gEnabled) return;

    // 进度回到开头 -> 重新武装（新视频开始）
    if (maxP < 0.08) {
        gArmed = YES;
    }
    // 进度到顶 -> 播完
    if (gArmed && maxP >= kEndThreshold) {
        gArmed = NO;
        [self videoEnded];
    }
}

- (void)videoEnded {
    if (!gEnabled) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastFire < kCooldown) return;
    gLastFire = now;
    DYLog(@">>>播完触发 %.2f", gLastPercent);
    dispatch_async(dispatch_get_main_queue(), ^{ [self performScroll]; });
}

- (void)performScroll {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    gScrollCount++;

    NSMutableArray<UIScrollView *> *svs = [NSMutableArray array];
    [self collectScrollViews:win.layer into:svs];
    UIScrollView *sv = nil;
    for (UIScrollView *c in svs) {
        if ([c isKindOfClass:[UICollectionView class]]) { sv = c; break; }
    }
    if (!sv) sv = svs.firstObject;

    if (sv) {
        CGFloat page = sv.bounds.size.height;
        CGFloat maxY = sv.contentSize.height - sv.bounds.size.height;
        CGFloat targetY = MIN(sv.contentOffset.y + page, maxY);
        if (targetY > sv.contentOffset.y + 2.0) {
            [sv setContentOffset:CGPointMake(sv.contentOffset.x, targetY) animated:YES];
            DYLog(@"上滑执行 page=%.0f", page);
            return;
        }
    }
    DYLog(@"!!未找到可滚动容器");
}

- (void)collectScrollViews:(CALayer *)layer into:(NSMutableArray<UIScrollView *> *)out {
    UIView *view = (UIView *)layer.delegate;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        CGFloat h = [UIScreen mainScreen].bounds.size.height;
        if (sv.bounds.size.height >= h * 0.7 && sv.contentSize.height > sv.bounds.size.height + 2.0) {
            [out addObject:sv];
        }
    }
    for (CALayer *sub in layer.sublayers) [self collectScrollViews:sub into:out];
}

#pragma mark - 开关 + 诊断

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
    if (gEnabled) {
        [btn setTitle:@"自动滑 ▮" forState:UIControlStateNormal];
        btn.backgroundColor = [[UIColor colorWithRed:0.10 green:0.72 blue:0.36 alpha:1.0] colorWithAlphaComponent:0.72];
    } else {
        [btn setTitle:@"自动滑 ○" forState:UIControlStateNormal];
        btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.50];
    }
    [win bringSubviewToFront:btn];
}

- (void)toggleSwitch {
    gEnabled = !gEnabled;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:gEnabled forKey:kEnabledKey];
    [ud synchronize];
    gArmed = YES;
    [self ensureSwitchButton];
    [self showToast:gEnabled ? @"自动上滑：已开启" : @"自动上滑：已关闭"];
}

- (void)showDiagnostics:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSString *events = gEvents.count ? [gEvents componentsJoinedByString:@"\n"] : @"（暂无事件）";
    NSString *pinfo = gProgressInfo.length > 180 ? [gProgressInfo substringToIndex:180] : gProgressInfo;
    NSString *msg = [NSString stringWithFormat:
        @"Bundle：%@\n开关：%@\n"
        "进度视图：%d 个\n当前进度：%.2f → %.2f\n"
        "触发：%d 上滑：%d\n页面：%@\n"
        "【进度详情】%@\n\n【最近事件】\n%@",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"?", gEnabled ? @"开" : @"关",
        gProgressViews, gPrevPercent, gLastPercent,
        gScrollCount, gScrollCount, NSStringFromClass([DYTopVC() class]), pinfo, events];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自动滑 · 诊断"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"测试上滑" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self performScroll]; });
    }]];
    UIViewController *top = DYTopVC();
    if (top.presentedViewController == nil) [top presentViewController:ac animated:YES completion:nil];
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
    CGSize fit = [label sizeThatFits:CGSizeMake(300.0, 44.0)];
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
