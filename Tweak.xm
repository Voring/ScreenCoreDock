//
//  Tweak.xm
//  ScreenCoreDock  v0.4.2
//
//  把 ScreenCore「全屏转ScreenCore分屏」改为「全屏转侧贴浮窗」。
//
//  功能清单（本版只保留这些）：
//    1. 打开分屏后补一次 dock（v0.1.0 基线，corner 取 splitDefaultDockSide）。
//    2. 横屏也能转侧贴（v0.1.8）：dock 被方向守卫拒掉时临时顶成竖屏重入，再兜底走 DockManager。
//    3. 转进横屏不强制收回侧贴（v0.1.9）。
//    4. 横屏卡片缩到 1/4 并重排（v0.2.x）：LandscapeDockScale 默认 0.5，左右间距对齐，顶部加一点点。
//    5. 浮窗左侧手势区改为关闭浮窗（v0.3.1），顶部仍为全屏。
//    6. 拖动浮窗到底部中央窄条松手转全屏（v0.3.8，触发区高 75pt）。
//
//  通知中心与锁屏下的收起行为由 ScreenCore 原生负责（v0.4.2 移除了自 v0.3.5 起的保留拦截）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define SC_DOMAIN CFSTR("com.susudear.screencore")

// 日志同时写文件：/var/mobile/Library/Logs/ScreenCoreDock.log（不可写则 /tmp/ScreenCoreDock.log）
static void SCLogAppend(NSString *msg) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = @"/var/mobile/Library/Logs";
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *p = [dir stringByAppendingPathComponent:@"ScreenCoreDock.log"];
        if (![fm isWritableFileAtPath:dir]) p = @"/tmp/ScreenCoreDock.log";
        path = p;
    });
    if (!path) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

#define SC_LOG(fmt, ...) do { \
    NSString *_m = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    NSLog(@"[ScreenCoreDock] %@", _m); \
    SCLogAppend(_m); \
} while (0)

// 只做声明，不提供实现；运行时类由 ScreenCore.dylib 提供。
@interface SCFloatingSceneManager : NSObject
- (BOOL)sc_openFrontmostApplicationAsSplitFromSourceRect:(CGRect)rect;   // 0x48eb8
- (id)activeSession;
- (id)dockManager;
- (NSInteger)activeHostOrientation;                                     // 1 竖屏 / 2 倒竖屏 / 3、4 横屏
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;        // 0x463ac
- (BOOL)sc_dockSessionForSingleActiveWindow:(id)session;                // 0x462e4
@end

@interface SCFloatingSceneManager (Orientation)
- (void)sc_activeHostOrientationDidChange:(NSInteger)orientation duration:(double)duration;
@end

// 区域 action 绑定：0x34628 处 Top/Left -> sc_handleFullscreenTap:（0x385b8）
//                           Bottom/Right -> sc_handleCloseTap:（0x3853c）
@interface SCFloatingContainerView : NSObject
- (void)sc_handleFullscreenTap:(id)gesture;
- (void)sc_handleCloseTap:(id)gesture;
- (void)sc_handleMoveGesture:(UIPanGestureRecognizer *)gesture;
- (BOOL)isDocked;
@end

@interface SCFloatingDockManager : NSObject
- (NSInteger)hostOrientation;                                          // 0x3fb28
- (UIView *)hostRootView;
- (NSDictionary *)sc_targetFramesForSide:(NSInteger)side;               // 0x3a384
- (void)sc_layoutSide:(NSInteger)side animated:(BOOL)animated completion:(void (^)(void))completion;  // 0x3b1fc
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;        // 0x3bde4
- (void)sc_restoreAllDockedSessionsAnimated:(BOOL)animated;             // 0x3d13c
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);
static BOOL (*orig_dockSession)(id, SEL, id, NSInteger);
static NSInteger (*orig_activeHostOrientation)(id, SEL);
static void (*orig_orientationDidChange)(id, SEL, NSInteger, double);
static void (*orig_restoreAllDocked)(id, SEL, BOOL);
static NSDictionary *(*orig_targetFramesForSide)(id, SEL, NSInteger);
static void (*orig_handleFullscreenTap)(id, SEL, id);
static void (*orig_handleMoveGesture)(id, SEL, id);

// 只在横屏重入 dock 期间为 YES
static BOOL sc_forcePortrait = NO;
// 只在插件处理方向切换期间为 YES
static BOOL sc_inOrientationChange = NO;

static NSInteger sc_defaultDockCorner(void) {
    NSNumber *side = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"), SC_DOMAIN);
    if (![side isKindOfClass:[NSNumber class]]) return 1;
    return ([side integerValue] == 1) ? 2 : 1;
}

#pragma mark - 横屏放开 dock 入口

static NSInteger hook_activeHostOrientation(id self, SEL _cmd) {
    if (sc_forcePortrait) return 1;
    return orig_activeHostOrientation(self, _cmd);
}

static BOOL hook_dockSession(id self, SEL _cmd, id session, NSInteger corner) {
    BOOL ok = orig_dockSession(self, _cmd, session, corner);
    if (ok) return YES;

    NSInteger orientation = 1;
    @try {
        orientation = [(SCFloatingSceneManager *)self activeHostOrientation];
    } @catch (__unused NSException *e) {}

    // 竖屏被拒是别的原因（session 不 live / 已 dock / 槽位满），不插手
    if (orientation < 3) return NO;

    sc_forcePortrait = YES;
    @try {
        ok = orig_dockSession(self, _cmd, session, corner);
    } @finally {
        sc_forcePortrait = NO;
    }
    if (ok) {
        SC_LOG(@"landscape dock ok via forced-orientation retry");
        return YES;
    }

    // 兜底：DockManager 层没有方向守卫
    id dock = nil;
    @try { dock = [(SCFloatingSceneManager *)self dockManager]; }
    @catch (__unused NSException *e) {}
    if ([dock respondsToSelector:@selector(sc_dockSession:fromCorner:)]) {
        @try {
            ok = [(SCFloatingDockManager *)dock sc_dockSession:session fromCorner:corner];
        } @catch (NSException *e) {
            SC_LOG(@"dockManager fallback threw %@", e.reason);
        }
    }
    return ok;
}

#pragma mark - 左侧手势区改为关闭浮窗

static void hook_handleFullscreenTap(id self, SEL _cmd, id gesture) {
    UIView *region = nil;
    NSString *ident = nil;
    @try {
        region = [gesture view];
        ident = [region accessibilityIdentifier];
    } @catch (__unused NSException *e) {}

    if (ident && [ident isEqualToString:@"ScreenCore.Split.LeftMoveFullscreen"]) {
        [(SCFloatingContainerView *)self sc_handleCloseTap:gesture];
        return;
    }
    orig_handleFullscreenTap(self, _cmd, gesture);
}

#pragma mark - 拖到底部中央窄条松手转全屏

// 底部中央触发区：高 75pt（自底边向上），宽取小横条宽度（134pt），水平居中。
static BOOL sc_inBottomCenterStrip(CGRect frame, CGRect hostBounds) {
    const CGFloat stripH = 75.0;
    const CGFloat stripW = 134.0;
    CGFloat bottom = CGRectGetMaxY(hostBounds);
    CGFloat centerX = CGRectGetMidX(hostBounds);
    CGFloat frameCenterX = frame.origin.x + frame.size.width * 0.5;
    if (CGRectGetMaxY(frame) < bottom - stripH) return NO;
    if (frameCenterX < centerX - stripW * 0.5) return NO;
    if (frameCenterX > centerX + stripW * 0.5) return NO;
    return YES;
}

static void hook_handleMoveGesture(id self, SEL _cmd, UIPanGestureRecognizer *gesture) {
    orig_handleMoveGesture(self, _cmd, gesture);

    @try {
        if (!gesture || gesture.state != UIGestureRecognizerStateEnded) return;
        if ([self respondsToSelector:@selector(isDocked)] && [self isDocked]) return;

        UIView *view = (UIView *)self;
        UIView *host = [view superview];
        CGRect hostBounds = host ? host.bounds : [UIScreen mainScreen].bounds;
        CGRect frame = host ? [view convertRect:view.bounds toView:host] : view.frame;

        if (sc_inBottomCenterStrip(frame, hostBounds)) {
            SC_LOG(@"drag-to-bottom-center -> fullscreen, frame=%@",
                   NSStringFromCGRect(frame));
            [(SCFloatingContainerView *)self sc_handleFullscreenTap:gesture];
        }
    } @catch (NSException *e) {
        SC_LOG(@"drag-to-fullscreen threw %@", e.reason);
    }
}

#pragma mark - 转横屏不强制收回 + 横屏重排

static void hook_orientationDidChange(id self, SEL _cmd, NSInteger orientation, double duration) {
    sc_inOrientationChange = YES;
    @try {
        orig_orientationDidChange(self, _cmd, orientation, duration);
    } @finally {
        sc_inOrientationChange = NO;
    }

    // 转进横屏后补一次侧边布局，让缩放后的帧真正落地
    if (orientation < 3) return;

    id dock = nil;
    @try { dock = [(SCFloatingSceneManager *)self dockManager]; }
    @catch (__unused NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try {
                for (NSInteger side = 1; side <= 2; side++) {
                    if ([dock respondsToSelector:@selector(sc_layoutSide:animated:completion:)]) {
                        [(SCFloatingDockManager *)dock sc_layoutSide:side animated:NO completion:nil];
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    });
}

static void hook_restoreAllDocked(id self, SEL _cmd, BOOL animated) {
    if (sc_inOrientationChange) {
        NSInteger host = 0;
        @try {
            if ([self respondsToSelector:@selector(hostOrientation)]) {
                host = [(SCFloatingDockManager *)self hostOrientation];
            }
        } @catch (__unused NSException *e) {}
        if (host >= 3) return;
    }
    orig_restoreAllDocked(self, _cmd, animated);
}

#pragma mark - 横屏卡片缩放与间距

static CGFloat sc_statusBarHeight(void) {
    NSNumber *n = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("splitPortraitTopSpacing"), SC_DOMAIN);
    CGFloat h = 0;
    if ([n isKindOfClass:[NSNumber class]]) h = [n doubleValue];
    if (h <= 0) {
        CGRect sb = [UIApplication sharedApplication].statusBarFrame;
        h = MIN(CGRectGetWidth(sb), CGRectGetHeight(sb));
    }
    if (h <= 0 || h > 200) h = 44.0;
    return h;
}

static CGFloat sc_landscapeScale(void) {
    CGFloat s = 0.5;
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("LandscapeDockScale"),
                                                    CFSTR("com.voring.screencoredock"));
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) s = [(__bridge NSNumber *)v doubleValue];
        CFRelease(v);
    }
    if (s < 0.2) s = 0.2;
    if (s > 1.0) s = 1.0;
    return s;
}

static NSDictionary *hook_targetFramesForSide(id self, SEL _cmd, NSInteger side) {
    NSDictionary *frames = orig_targetFramesForSide(self, _cmd, side);
    if (frames.count == 0 || sc_forcePortrait) return frames;

    NSInteger host = 0;
    @try { host = [(SCFloatingDockManager *)self hostOrientation]; }
    @catch (__unused NSException *e) {}
    if (host < 3) return frames;

    CGRect bounds = CGRectZero;
    @try {
        UIView *root = [(SCFloatingDockManager *)self hostRootView];
        if (root) bounds = root.bounds;
    } @catch (__unused NSException *e) {}
    if (CGRectIsEmpty(bounds)) return frames;

    CGFloat scale = sc_landscapeScale();
    NSArray *keys = [[frames allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        CGRect fa = [(NSValue *)frames[a] CGRectValue];
        CGRect fb = [(NSValue *)frames[b] CGRectValue];
        if (fa.origin.y < fb.origin.y) return NSOrderedAscending;
        if (fa.origin.y > fb.origin.y) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    if (keys.count == 0) return frames;

    CGRect first = [(NSValue *)frames[keys.firstObject] CGRectValue];
    // 左右间距：保持右侧那个视觉间距（8 + 缩掉的那部分宽度），左侧照抄同一值。
    // 顶部只取「该间距 + 状态栏高度」的 1/4。
    CGFloat margin = 8.0 + first.size.width * (1.0 - scale);
    CGFloat topGap = (margin + sc_statusBarHeight()) * 0.25;
    BOOL isRight = (CGRectGetMidX(first) > CGRectGetMidX(bounds));
    CGFloat y = CGRectGetMinY(bounds) + topGap;
    CGFloat gap = 18.0 * scale;

    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:keys.count];
    for (id key in keys) {
        CGRect old = [(NSValue *)frames[key] CGRectValue];
        CGSize size = CGSizeMake(old.size.width * scale, old.size.height * scale);
        if (CGRectGetMaxY(bounds) - y < size.height) {
            y = MAX(CGRectGetMinY(bounds), CGRectGetMaxY(bounds) - size.height);
        }
        CGFloat x = isRight ? (CGRectGetMaxX(bounds) - margin - size.width)
                            : (CGRectGetMinX(bounds) + margin);
        CGRect nr = CGRectMake(x, y, size.width, size.height);
        out[key] = [NSValue valueWithCGRect:nr];
        y = CGRectGetMaxY(nr) + gap;
    }
    return out;
}

#pragma mark - 入口

static void sc_dockSessionIfPossible(SCFloatingSceneManager *manager) {
    id session = [manager activeSession];
    if (!session) return;

    NSInteger corner = sc_defaultDockCorner();
    BOOL docked = NO;
    @try {
        docked = [manager sc_dockSession:session fromCorner:corner];
    } @catch (NSException *e) {
        SC_LOG(@"sc_dockSession:fromCorner: threw %@", e.reason);
    }
    if (!docked) {
        @try {
            docked = [manager sc_dockSessionForSingleActiveWindow:session];
        } @catch (NSException *e) {
            SC_LOG(@"sc_dockSessionForSingleActiveWindow: threw %@", e.reason);
        }
    }
    SC_LOG(@"dock corner=%ld ok=%d", (long)corner, docked);
}

static BOOL hook_openFrontmostAsSplit(id self, SEL _cmd, CGRect rect) {
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
    if (!result) return result;

    @autoreleasepool {
        sc_dockSessionIfPossible((SCFloatingSceneManager *)self);
    }
    return result;
}

static void installHook(int attempt) {
    Class cls = objc_getClass("SCFloatingSceneManager");
    if (!cls) {
        if (attempt >= 50) {
            SC_LOG(@"SCFloatingSceneManager not found, hook aborted");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            installHook(attempt + 1);
        });
        return;
    }

    MSHookMessageEx(cls,
                    @selector(sc_openFrontmostApplicationAsSplitFromSourceRect:),
                    (IMP)hook_openFrontmostAsSplit,
                    (IMP *)&orig_openFrontmostAsSplit);

    MSHookMessageEx(cls,
                    @selector(sc_dockSession:fromCorner:),
                    (IMP)hook_dockSession,
                    (IMP *)&orig_dockSession);

    if ([cls instancesRespondToSelector:@selector(activeHostOrientation)]) {
        MSHookMessageEx(cls,
                        @selector(activeHostOrientation),
                        (IMP)hook_activeHostOrientation,
                        (IMP *)&orig_activeHostOrientation);
    }

    if ([cls instancesRespondToSelector:@selector(sc_activeHostOrientationDidChange:duration:)]) {
        MSHookMessageEx(cls,
                        @selector(sc_activeHostOrientationDidChange:duration:),
                        (IMP)hook_orientationDidChange,
                        (IMP *)&orig_orientationDidChange);
    }

    Class containerCls = objc_getClass("SCFloatingContainerView");
    if (containerCls &&
        [containerCls instancesRespondToSelector:@selector(sc_handleFullscreenTap:)] &&
        [containerCls instancesRespondToSelector:@selector(sc_handleCloseTap:)]) {
        MSHookMessageEx(containerCls,
                        @selector(sc_handleFullscreenTap:),
                        (IMP)hook_handleFullscreenTap,
                        (IMP *)&orig_handleFullscreenTap);

        if ([containerCls instancesRespondToSelector:@selector(sc_handleMoveGesture:)]) {
            MSHookMessageEx(containerCls,
                            @selector(sc_handleMoveGesture:),
                            (IMP)hook_handleMoveGesture,
                            (IMP *)&orig_handleMoveGesture);
        }
    }

    Class dockCls = objc_getClass("SCFloatingDockManager");
    if (dockCls) {
        if ([dockCls instancesRespondToSelector:@selector(sc_targetFramesForSide:)]) {
            MSHookMessageEx(dockCls,
                            @selector(sc_targetFramesForSide:),
                            (IMP)hook_targetFramesForSide,
                            (IMP *)&orig_targetFramesForSide);
        }
        if ([dockCls instancesRespondToSelector:@selector(sc_restoreAllDockedSessionsAnimated:)]) {
            MSHookMessageEx(dockCls,
                            @selector(sc_restoreAllDockedSessionsAnimated:),
                            (IMP)hook_restoreAllDocked,
                            (IMP *)&orig_restoreAllDocked);
        }
    }

    SC_LOG(@"hooked: open + dockSession + orientation + restoreAllDocked + targetFrames + leftRegionClose");
}

%ctor {
    @autoreleasepool {
        SC_LOG(@"v0.4.2 loaded in %@", [[NSProcessInfo processInfo] processName]);
        installHook(0);
    }
}
