//
//  DouyinAutoScroll.m
//  抖音播放完毕自动上滑下一个视频 —— 巨魔 TrollFools 注入用动态库
//
//  目标：iOS 15.4.1 / 抖音 37.9.0 (com.ss.iphone.ugc.Aweme)
//  产物：DouyinAutoScroll.dylib （单文件，无需 Substrate/Substitute 依赖）
//
//  检测播放结束采用三重保险：
//   1) AVPlayerItemDidPlayToEndTimeNotification
//   2) 轮询视图树里的 AVPlayerLayer，currentTime 接近 duration
//   3) Hook 抖音进度回调 AWEPlayInteractionProgressController
//      -updateProgressSliderWithTime:totalDuration:
//  任意一路命中即触发一次上滑，带冷却时间防止重复触发。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - 可调参数（按需修改后重新编译）

// 距离视频结尾多少秒判定为“播放完毕”
static const NSTimeInterval kEndTolerance = 0.30;
// 两次自动上滑之间的最小间隔，防止连续触发
static const NSTimeInterval kScrollCooldown = 1.20;
// AVPlayerLayer 轮询周期
static const NSTimeInterval kPollInterval = 0.25;
// 当 ListView 不是分页模式时，改用 scrollToItem 翻页
static const BOOL kUseScrollToItemFallback = YES;
// 是否显示左上角悬浮总开关
static const BOOL kShowFloatingSwitch = YES;
// 开关状态持久化 key
static NSString *const kEnabledKey = @"com.douyin.autoscroll.enabled";
// 悬浮按钮 tag，避免重复添加
static const NSInteger kSwitchTag = 887712;

#pragma mark - 工具函数

static BOOL DYIsTargetApp(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    // com.ss.iphone.ugc.Aweme / com.ss.iphone.ugc.AwemeLite 等
    return [bid rangeOfString:@"Aweme"].location != NSNotFound;
}

static UIViewController *DYTopViewController(void) {
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = [(UITabBarController *)vc selectedViewController];
        if (selected) vc = selected;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = [(UINavigationController *)vc topViewController];
        if (top) vc = top;
    }
    return vc;
}

// 仅在推荐流/视频详情页触发，避开直播间等场景
static BOOL DYOnMainFeed(void) {
    UIViewController *vc = DYTopViewController();
    NSString *name = NSStringFromClass([vc class]);
    if ([name rangeOfString:@"Live"].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Feed"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"AwemeDetail"].location != NSNotFound) return YES;
    return NO;
}

static void DYCollectScrollViews(UIView *view, NSMutableArray<UIScrollView *> *out) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        // 全屏、且内容高度大于可视高度，才可能是视频流
        if (sv.bounds.size.height >= screenH * 0.72 &&
            sv.contentSize.height > sv.bounds.size.height + 2.0) {
            [out addObject:sv];
        }
    }
    for (UIView *subview in view.subviews) {
        DYCollectScrollViews(subview, out);
    }
}

static void DYCollectPlayerLayers(CALayer *layer, NSMutableArray<AVPlayerLayer *> *out) {
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        [out addObject:(AVPlayerLayer *)layer];
    }
    for (CALayer *sublayer in layer.sublayers) {
        DYCollectPlayerLayers(sublayer, out);
    }
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

#pragma mark - Progress Hook

// 抖音 35.x/37.x 中该方法签名为 (CGFloat, CGFloat)，arm64 下即 double
static IMP gOriginalProgressIMP = NULL;
static BOOL gProgressHooked = NO;

static void DYProgressHook(id self, SEL _cmd, double currentTime, double totalDuration) {
    if (gOriginalProgressIMP) {
        ((void (*)(id, SEL, double, double))gOriginalProgressIMP)(self, _cmd, currentTime, totalDuration);
    }
    DYAutoScrollManager *manager = [DYAutoScrollManager sharedInstance];
    if (currentTime < 1.0) manager.armed = YES;
    if (manager.armed &&
        totalDuration > 0.5 &&
        currentTime >= totalDuration - kEndTolerance) {
        manager.armed = NO;
        [manager videoReachedEnd];
    }
}

#pragma mark - Manager 实现

@implementation DYAutoScrollManager

+ (instancetype)sharedInstance {
    static DYAutoScrollManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _armed = YES;
        _enabled = [self loadEnabledState];
    }
    return self;
}

// NSUserDefaults 为主，同时支持在 App 的 Documents 放一个 plist 覆盖设置
- (BOOL)loadEnabledState {
    BOOL state = YES; // 默认开启，用户可通过悬浮开关随时关闭
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey];
    if (stored) state = [stored boolValue];

    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/DouyinAutoScroll.plist"];
    NSDictionary *fileConfig = [NSDictionary dictionaryWithContentsOfFile:path];
    id override = [fileConfig objectForKey:@"Enabled"];
    if (override) state = [override boolValue];
    return state;
}

- (void)start {
    [self installHooks];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handlePlayerItemEnd:)
                   name:AVPlayerItemDidPlayToEndTimeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(appBecameActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    if (!self.pollTimer) {
        self.pollTimer = [NSTimer timerWithTimeInterval:kPollInterval
                                                target:self
                                              selector:@selector(pollPlayers:)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
    }
    [self ensureSwitchButton];
}

- (void)installHooks {
    if (gProgressHooked) return;
    Class cls = objc_getClass("AWEPlayInteractionProgressController");
    if (!cls) return;

    SEL sel = sel_registerName("updateProgressSliderWithTime:totalDuration:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    // 参数必须是 double，签名不一致就跳过，避免破坏原逻辑
    char *arg2 = method_copyArgumentType(method, 2);
    char *arg3 = method_copyArgumentType(method, 3);
    BOOL signatureOK = (arg2 && arg3 && arg2[0] == 'd' && arg3[0] == 'd');
    free(arg2);
    free(arg3);
    if (!signatureOK) return;

    IMP original = method_getImplementation(method);
    if (!original) return;

    class_replaceMethod(cls, sel, (IMP)DYProgressHook, method_getTypeEncoding(method));
    gOriginalProgressIMP = original;
    gProgressHooked = YES;
}

- (void)appBecameActive:(NSNotification *)notification {
    // 抖音切后台回来 keyWindow 可能变化，重新挂开关、补装 Hook
    [self installHooks];
    [self ensureSwitchButton];
}

- (void)handlePlayerItemEnd:(NSNotification *)notification {
    if (!self.enabled) return;
    if (!DYOnMainFeed()) return;
    self.armed = NO;
    [self videoReachedEnd];
}

- (void)pollPlayers:(NSTimer *)timer {
    if (!self.enabled) return;
    if (!DYOnMainFeed()) return;

    NSMutableArray<AVPlayerLayer *> *layers = [NSMutableArray array];
    DYCollectPlayerLayers([UIApplication sharedApplication].keyWindow.layer, layers);
    if (layers.count == 0) return;

    AVPlayer *activePlayer = nil;
    for (AVPlayerLayer *playerLayer in layers) {
        AVPlayer *player = playerLayer.player;
        if (!player || !player.currentItem) continue;
        if (player.rate > 0.0) {
            activePlayer = player;
            break;
        }
        if (!activePlayer && CMTimeGetSeconds(player.currentTime) > 0.5) {
            activePlayer = player; // 有些版本在结尾会把 rate 置 0
        }
    }
    if (!activePlayer) return;

    CMTime current = activePlayer.currentTime;
    CMTime duration = activePlayer.currentItem.duration;
    if (!CMTIME_IS_VALID(current) || !CMTIME_IS_VALID(duration)) return;

    double t = CMTimeGetSeconds(current);
    double d = CMTimeGetSeconds(duration);
    if (isnan(t) || isnan(d)) return;

    if (t < 1.0) self.armed = YES;
    if (self.armed && d > 0.5 && t >= d - kEndTolerance) {
        self.armed = NO;
        [self videoReachedEnd];
    }
}

- (void)videoReachedEnd {
    if (!self.enabled) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastTrigger < kScrollCooldown) return;
    self.lastTrigger = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self scrollToNextVideo];
    });
}

- (void)scrollToNextVideo {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    NSMutableArray<UIScrollView *> *scrollViews = [NSMutableArray array];
    UIViewController *top = DYTopViewController();
    if (top.view) DYCollectScrollViews(top.view, scrollViews);
    if (scrollViews.count == 0) DYCollectScrollViews(window, scrollViews);
    if (scrollViews.count == 0) return;

    // 视频流一般是 UICollectionView，优先选它
    UIScrollView *scrollView = nil;
    for (UIScrollView *candidate in scrollViews) {
        if ([candidate isKindOfClass:[UICollectionView class]]) {
            scrollView = candidate;
            break;
        }
    }
    if (!scrollView) scrollView = [scrollViews firstObject];

    // 非分页模式：用 indexPath 精确翻到下一条
    if (kUseScrollToItemFallback &&
        [scrollView isKindOfClass:[UICollectionView class]] &&
        !scrollView.pagingEnabled) {
        UICollectionView *collectionView = (UICollectionView *)scrollView;
        NSIndexPath *visible = collectionView.indexPathsForVisibleItems.firstObject;
        if (visible) {
            NSInteger nextItem = visible.item + 1;
            if (nextItem < [collectionView numberOfItemsInSection:visible.section]) {
                NSIndexPath *nextPath = [NSIndexPath indexPathForItem:nextItem
                                                            inSection:visible.section];
                [collectionView scrollToItemAtIndexPath:nextPath
                                       atScrollPosition:UICollectionViewScrollPositionTop
                                               animated:YES];
                return;
            }
        }
    }

    // 分页模式：按一屏高度上滑
    CGFloat pageHeight = scrollView.bounds.size.height;
    CGFloat maxOffsetY = scrollView.contentSize.height - scrollView.bounds.size.height;
    CGFloat targetY = MIN(scrollView.contentOffset.y + pageHeight, maxOffsetY);
    if (targetY <= scrollView.contentOffset.y + 2.0) return; // 已经到底，交给抖音加载更多
    [scrollView setContentOffset:CGPointMake(scrollView.contentOffset.x, targetY) animated:YES];
}

#pragma mark - 悬浮总开关

- (void)ensureSwitchButton {
    if (!kShowFloatingSwitch) return;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    UIButton *button = (UIButton *)[window viewWithTag:kSwitchTag];
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = kSwitchTag;
        button.layer.cornerRadius = 15.0;
        button.layer.masksToBounds = YES;
        button.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [button addTarget:self
                   action:@selector(toggleSwitch)
         forControlEvents:UIControlEventTouchUpInside];
        [window addSubview:button];
    }

    button.frame = CGRectMake(10.0, window.safeAreaInsets.top + 8.0, 78.0, 30.0);
    if (self.enabled) {
        [button setTitle:@"自动滑 ▮" forState:UIControlStateNormal];
        button.backgroundColor = [[UIColor colorWithRed:0.10 green:0.72 blue:0.36 alpha:1.0]
                                  colorWithAlphaComponent:0.72];
    } else {
        [button setTitle:@"自动滑 ○" forState:UIControlStateNormal];
        button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.50];
    }
    [window bringSubviewToFront:button];
}

- (void)toggleSwitch {
    self.enabled = !self.enabled;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:self.enabled forKey:kEnabledKey];
    [defaults synchronize];
    self.armed = YES;
    [self ensureSwitchButton];
    [self showToast:self.enabled ? @"自动上滑：已开启" : @"自动上滑：已关闭"];
}

- (void)showToast:(NSString *)text {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
    label.font = [UIFont systemFontOfSize:14.0];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 8.0;
    label.layer.masksToBounds = YES;

    CGSize fit = [label sizeThatFits:CGSizeMake(280.0, 44.0)];
    label.frame = CGRectMake((window.bounds.size.width - fit.width - 24.0) / 2.0,
                             window.bounds.size.height * 0.72,
                             fit.width + 24.0,
                             fit.height + 16.0);
    label.alpha = 0.0;
    [window addSubview:label];
    [window bringSubviewToFront:label];

    [UIView animateWithDuration:0.2 animations:^{
        label.alpha = 1.0;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.25
                              delay:1.2
                            options:0
                         animations:^{ label.alpha = 0.0; }
                         completion:^(BOOL done) { [label removeFromSuperview]; }];
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
