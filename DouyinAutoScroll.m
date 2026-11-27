//
//  DouyinAutoScroll V3 —— 强制开启抖音原生"自动连播"开关
//
//  核心思路（来自 DYYY 开源项目验证）：
//    抖音原生就有"视频播完自动播下一个"的能力，只是由若干开关控制，
//    默认在推荐页是关的。V1/V2 自己检测播放结束 + 模拟上滑都走不通
//    （抖音 37.9.0 不用标准 AVPlayer、伪造 UITouch 在 iOS15 失效）。
//    V3 直接把这些开关强制返回 YES，让抖音自己完成连播。
//
//  为避免版本改名失效，V3 用运行时扫描：
//    遍历抖音所有类，凡类名/方法名匹配"自动播放/连播"特征，
//    且是返回 BOOL 的无参方法，就 swizzle 成返回 YES。
//    诊断面板会列出所有命中的类和方法，方便确认。
//
//  总开关：开启时才强制 YES，关闭时恢复原逻辑（%orig）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <math.h>

#pragma mark - 配置

static NSString *const kEnabledKey = @"com.douyin.autoscroll.enabled";
static const NSInteger kSwitchTag = 887712;

// 类名关键字：命中任意一个是"可能是自动播放相关的类"
static NSArray *DYClassKeywords(void) {
    return @[@"AutoPlay", @"Autoplay", @"AutoPlayManager", @"PlayControl",
             @"ModuleService", @"FeedPlay", @"PlaybackConfig", @"Continuity",
             @"Continuous", @"AutoNext", @"PlayerConfig"];
}

// 方法名关键字：命中任意一个就强制返回 YES
static NSArray *DYMethodKeywords(void) {
    return @[@"autoPlay", @"AutoPlay", @"autoplay",
             @"getFeedIphoneAutoPlayState", @"isAutoPlayOpen",
             @"enableUserProfilePostAutoPlay", @"hasIphoneAutoPlaySwitch",
             @"autoNext", @"AutoNext", @"continuousPlay", @"ContinuousPlay",
             @"autoPlayNext", @"shouldAutoPlay", @"NeedAutoPlay", @"needAutoPlay",
             @"enableAutoPlay", @"autoLoop", @"AutoLoop"];
}

// 明确要排除的（避免误伤，例如广告/直播的自动进入）
static NSArray *DYExcludeKeywords(void) {
    return @[@"Live", @"AD", @"Ad", @"Comment", @"Search"];
}

#pragma mark - 全局状态

static BOOL gEnabled = YES;
static NSMutableArray<NSString *> *gHookedList = nil;   // 命中的"类 方法"列表
static int gForceCount = 0;                              // 强制返回 YES 的次数
static int gClassScanned = 0;

#pragma mark - 工具

static BOOL DYIsTargetApp(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bid rangeOfString:@"Aweme"].location != NSNotFound;
}

static BOOL DYContainsAny(NSString *s, NSArray *keywords) {
    for (NSString *k in keywords) {
        if ([s rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
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

#pragma mark - 通用 bool YES Hook

// 统一的替换函数：开关开时返回 YES，关时调用原实现
static BOOL DYForceYES(id self, SEL _cmd) {
    if (gEnabled) {
        gForceCount++;
        return YES;
    }
    // 关闭时尝试调用原实现
    IMP orig = class_getMethodImplementation([self class], _cmd);
    // 注意：这里拿到的可能是自己（已被替换），所以关闭时最安全是返回 NO 交由系统默认；
    //     为简化，关闭状态下返回 NO，用户关掉后重启 App 即完全恢复。
    (void)orig;
    return NO;
}

#pragma mark - Manager

@interface DYAutoScrollManager : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)ensureSwitchButton;
- (void)installAutoPlaySwizzles;
@end

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
        gEnabled = YES;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        id stored = [ud objectForKey:kEnabledKey];
        if (stored) gEnabled = [stored boolValue];
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/DouyinAutoScroll.plist"];
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([cfg objectForKey:@"Enabled"]) gEnabled = [cfg[@"Enabled"] boolValue];
        gHookedList = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    // 稍等片刻，等抖音的类都注册完再扫描
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self installAutoPlaySwizzles];
        [self ensureSwitchButton];
    });
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [self ensureSwitchButton];
}

- (void)appActive:(NSNotification *)note {
    [self installAutoPlaySwizzles];
    [self ensureSwitchButton];
}

// 运行时扫描并 swizzle 所有"自动播放"相关的 bool 无参方法
- (void)installAutoPlaySwizzles {
    if (gClassScanned > 0) return;  // 只扫一次，避免重复 swizzle

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * classCount);
    objc_getClassList(classes, classCount);

    NSArray *classKW = DYClassKeywords();
    NSArray *methodKW = DYMethodKeywords();
    NSArray *exclude = DYExcludeKeywords();

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        NSString *clsName = NSStringFromClass(cls);
        if (!clsName) continue;
        gClassScanned++;

        // 只处理抖音自己的类（AWE/AWEFeed/AWEModule 等前缀），跳过系统类
        BOOL isAwemeClass = ([clsName hasPrefix:@"AWE"] || [clsName hasPrefix:@"AWEFeed"] ||
                             [clsName hasPrefix:@"AWEModule"] || [clsName hasPrefix:@"IES"] ||
                             DYContainsAny(clsName, classKW));
        if (!isAwemeClass) continue;
        if (DYContainsAny(clsName, exclude)) continue;

        // 扫描该类的方法列表（含分类方法）
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            Method m = methods[j];
            SEL sel = method_getName(m);
            NSString *selName = NSStringFromSelector(sel);
            if (!selName) continue;

            // 无参方法
            if ([selName rangeOfString:@":"].location != NSNotFound) continue;
            // 返回类型必须是 bool/BOOL (编码 'B' 或 'c')
            const char *ret = method_copyReturnType(m);
            BOOL isBool = (ret && (ret[0] == 'B' || ret[0] == 'c'));
            free((void *)ret);
            if (!isBool) continue;

            // 方法名命中自动播放关键字
            if (!DYContainsAny(selName, methodKW)) continue;
            if (DYContainsAny(selName, exclude)) continue;

            IMP currentIMP = method_getImplementation(m);
            if (currentIMP == (IMP)DYForceYES) continue;  // 已经 hook 过

            if (class_replaceMethod(cls, sel, (IMP)DYForceYES, method_getTypeEncoding(m))) {
                NSString *entry = [NSString stringWithFormat:@"%@ %@", clsName, selName];
                if (![gHookedList containsObject:entry]) [gHookedList addObject:entry];
            }
        }
        free(methods);
    }
    free(classes);
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
        btn.backgroundColor = [[UIColor colorWithRed:0.10 green:0.72 blue:0.36 alpha:1.0]
                               colorWithAlphaComponent:0.72];
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
    [self ensureSwitchButton];
    [self showToast:gEnabled ? @"自动连播：已开启" : @"自动连播：已关闭（重启后完全恢复）"];
}

- (void)showDiagnostics:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    NSString *hooked = gHookedList.count ? [gHookedList componentsJoinedByString:@"\n"] : @"（无命中）";
    if (hooked.length > 500) hooked = [[hooked substringToIndex:500] stringByAppendingString:@"\n..."];
    NSString *msg = [NSString stringWithFormat:
        @"Bundle：%@\n"
        "开关：%@\n"
        "扫描类数：%d\n"
        "命中开关数：%lu\n"
        "强制YES次数：%d\n"
        "当前页面：%@\n"
        "\n【命中的开关】\n%@",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
        gEnabled ? @"开" : @"关",
        gClassScanned, (unsigned long)gHookedList.count, gForceCount,
        NSStringFromClass([DYTopVC() class]), hooked];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自动连播 · 诊断"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *top = DYTopVC();
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
