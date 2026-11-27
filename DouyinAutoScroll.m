//
//  DouyinAutoScroll V4 —— 读播放进度条判定播完 + Hook 播放器 KVO
//
//  演进：
//   V1 自己检测 AVPlayer + 改 contentOffset  →  37.9.0 不走标准 AVPlayer，失败
//   V2 模拟上滑手势 sendEvent                →  iOS15 伪造 UITouch 失效，失败
//   V3 强制打开抖音原生"自动连播"开关        →  推荐页无此开关，206 命中全是无关类，失败
//   V4 直接读进度条 applyWidthPercentToSubviews: 的百分比（UI 事实），
//      到 100% 视为播完并上滑；同时 Hook 播放器 KVO 记录 keyPath 供诊断。
//
//  长按开关弹出诊断面板：显示进度条/Hook 是否装上、进度调用次数、最后百分比、
//  KVO keyPath、最近事件，以及"测试上滑"按钮。
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

#pragma mark - 全局状态

static BOOL gEnabled = YES;
static BOOL gArmed = YES;
static NSTimeInterval gLastFire = 0;
static int gProgressCalls = 0;
static double gLastPercent = -1.0;
static int gKvoCalls = 0;
static NSString *gLastKeyPath = @"-";
static int gScrollCount = 0;
static int gFallbackCount = 0;
static int gProgressHooks = 0;      // 成功 hook 的进度方法数
static NSMutableArray<NSString *> *gEvents = nil;

static void DYLog(NSString *fmt, ...) {
    if (!gEvents) return;
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [gEvents addObject:line];
    if (gEvents.count > 14) [gEvents removeObjectAtIndex:0];
}

// 原始 IMP 查询（定义在下方，此处前向声明）
static IMP DYFindOrigIMP(Class cls, SEL sel);

#pragma mark - Manager 声明（Hook 函数会用到，必须先声明）

@interface DYAutoScrollManager : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)installHooks;
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

#pragma mark - Hook 实现

// 进度条百分比：0→1，到 1 即视频播完
static void DYApplyWidthHook(id self, SEL _cmd, CGFloat percent) {
    // 调用原实现
    IMP realOrig = DYFindOrigIMP([self class], sel_registerName("applyWidthPercentToSubviews:"));
    if (realOrig && realOrig != (IMP)DYApplyWidthHook) {
        ((void (*)(id, SEL, CGFloat))realOrig)(self, _cmd, percent);
    }

    gProgressCalls++;
    gLastPercent = percent;
    if (percent < 0.05) gArmed = YES;
    if (gArmed && percent >= 0.99) {
        gArmed = NO;
        DYAutoScrollManager *m = [DYAutoScrollManager sharedInstance];
        [m videoEnded];
    }
}

// 播放器 KVO：只记录 keyPath 供诊断
static void DYKVOHook(id self, SEL _cmd, NSString *keyPath, id object, NSDictionary *change, void *context) {
    IMP realOrig = DYFindOrigIMP([self class], sel_registerName("observeValueForKeyPath:ofObject:change:context:"));
    if (realOrig && realOrig != (IMP)DYKVOHook) {
        ((void (*)(id, SEL, NSString *, id, NSDictionary *, void *))realOrig)(self, _cmd, keyPath, object, change, context);
    }
    gKvoCalls++;
    gLastKeyPath = keyPath ?: @"?";
    if (gKvoCalls <= 30) DYLog(@"KVO:%@=%@", keyPath, [change objectForKey:NSKeyValueChangeNewKey]);
}

// 原始 IMP 映射表（每个被 hook 的类各存一份）
typedef struct { Class cls; SEL sel; IMP imp; } DYOrigEntry;
static DYOrigEntry gOrigTable[64];
static int gOrigCount = 0;

static IMP DYFindOrigIMP(Class cls, SEL sel) {
    for (int i = 0; i < gOrigCount; i++) {
        if (gOrigTable[i].cls == cls && gOrigTable[i].sel == sel) return gOrigTable[i].imp;
    }
    // 沿父类找
    Class sup = class_getSuperclass(cls);
    while (sup) {
        for (int i = 0; i < gOrigCount; i++) {
            if (gOrigTable[i].cls == sup && gOrigTable[i].sel == sel) return gOrigTable[i].imp;
        }
        sup = class_getSuperclass(sup);
    }
    return NULL;
}

static void DYStoreOrig(Class cls, SEL sel, IMP imp) {
    if (gOrigCount < 64) {
        gOrigTable[gOrigCount].cls = cls;
        gOrigTable[gOrigCount].sel = sel;
        gOrigTable[gOrigCount].imp = imp;
        gOrigCount++;
    }
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
    [self installHooks];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [self ensureSwitchButton];
}

- (void)appActive:(NSNotification *)note {
    [self installHooks];
    [self ensureSwitchButton];
}

- (void)installHooks {
    if (gProgressHooks > 0) return;  // 已扫过

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    objc_getClassList(classes, count);

    SEL progressSel = sel_registerName("applyWidthPercentToSubviews:");
    SEL kvoSel = sel_registerName("observeValueForKeyPath:ofObject:change:context:");

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (!name || ![name hasPrefix:@"AWE"]) continue;

        // 1) 进度方法：凡 AWE 类里有 applyWidthPercentToSubviews: 就 hook
        Method pm = class_getInstanceMethod(cls, progressSel);
        if (pm) {
            char *arg = method_copyArgumentType(pm, 2);
            BOOL ok = arg && (arg[0] == 'd' || arg[0] == 'f');
            free(arg);
            if (ok) {
                IMP orig = method_getImplementation(pm);
                if (orig != (IMP)DYApplyWidthHook) {
                    DYStoreOrig(cls, progressSel, orig);
                    class_replaceMethod(cls, progressSel, (IMP)DYApplyWidthHook, method_getTypeEncoding(pm));
                    gProgressHooks++;
                    DYLog(@"进度Hook:%@", name);
                }
            }
        }

        // 2) 播放器 KVO：只 hook AWEAwemePlayVideoViewController
        if ([name isEqualToString:@"AWEAwemePlayVideoViewController"]) {
            Method km = class_getInstanceMethod(cls, kvoSel);
            if (km) {
                IMP orig = method_getImplementation(km);
                if (orig != (IMP)DYKVOHook) {
                    DYStoreOrig(cls, kvoSel, orig);
                    class_replaceMethod(cls, kvoSel, (IMP)DYKVOHook, method_getTypeEncoding(km));
                    DYLog(@"KVO Hook:%@", name);
                }
            }
        }
    }
    free(classes);
    if (gProgressHooks == 0) DYLog(@"!! 未找到任何进度方法");
}

- (void)videoEnded {
    if (!gEnabled) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastFire < kCooldown) return;
    gLastFire = now;
    DYLog(@">>>触发上滑 %.2f", gLastPercent);
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
            gFallbackCount++;
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
    NSString *msg = [NSString stringWithFormat:
        @"Bundle：%@\n开关：%@\n"
        "进度Hook数：%d\n进度调用：%d 次\n"
        "最后进度：%.3f\nKVO调用：%d 次\n"
        "最后keyPath：%@\n触发：%d 上滑：%d\n"
        "页面：%@\n\n【最近事件】\n%@",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"?", gEnabled ? @"开" : @"关",
        gProgressHooks, gProgressCalls, gLastPercent, gKvoCalls, gLastKeyPath,
        gScrollCount, gFallbackCount, NSStringFromClass([DYTopVC() class]), events];

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
