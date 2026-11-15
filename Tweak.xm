//
//  Tweak.xm
//  ScreenCoreDock  v0.2.6
//
//  逻辑回退到 v0.1.0 初版：只有「打开分屏后补一次 dock」这一条逻辑，
//  去掉 v0.1.1~v0.1.7 的自由摆放 / FreeFloatMode / 帧表覆盖 / 收尾层 hook。
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」
//  (system-tool:fullscreen-to-screencore-split)
//  由「前台应用 -> 分屏浮窗（居中大窗口）」改为「前台应用 -> 侧贴浮窗（贴屏幕两侧的小卡片）」。
//
//  v0.1.0 基线：hook -sc_openFrontmostApplicationAsSplitFromSourceRect:（0x48eb8）
//    原方法返回后取 activeSession 调 -sc_dockSession:fromCorner:；
//    失败再走 -sc_dockSessionForSingleActiveWindow:。
//
//  v0.1.8：放开 -sc_dockSession:fromCorner:（0x463ac）的方向守卫（0x463e4 只接受 1/2）。
//  v0.1.9：解掉转横屏时 -sc_restoreAllDockedSessionsAnimated:（0x42ca8 尾部 0x42ee0）把侧贴全收回。
//  v0.2.0：横屏卡片过大，按 0.5 缩放并紧凑重排。
//  v0.2.1：横屏左右间距对齐。
//  v0.2.2：修安全模式（不再在初始化时遍历全类表，改按类名取类）。
//  v0.2.3：顶部间距缩到 1/4；横屏点角补 session 兜底。
//  v0.2.4：点角取 session 失败时再退 activeSession。
//  v0.2.5：日志落盘（/var/mobile/Library/Logs/ScreenCoreDock.log）。
//  v0.2.6：真机日志证明横屏点角根本没进 sc_handleDockTap:（手势层问题），
//          改为在容器上自建一个 tap 手势，点四角直接走 dock，不再依赖原手势；
//          同时记录四角 region 的实际 frame 以便核对。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define SC_DOMAIN CFSTR("com.susudear.screencore")

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
- (BOOL)sc_openFrontmostApplicationAsSplitFromSourceRect:(CGRect)rect;
- (id)activeSession;
- (id)dockManager;
- (NSInteger)activeHostOrientation;   // 1 竖屏 / 2 倒竖屏 / 3、4 横屏
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (BOOL)sc_dockSessionForSingleActiveWindow:(id)session;
@end

@interface SCFloatingSceneManager (Orientation)
- (void)sc_activeHostOrientationDidChange:(NSInteger)orientation duration:(double)duration;
@end

// sceneManager 的委托方法，横屏点角时要手动转发给它
@interface NSObject (SCDockFromCornerForwarding)
- (void)sc_floatingContainerView:(id)view didRequestDockFromCorner:(NSInteger)corner;
- (id)sc_sessionForContainerView:(id)view;
@end

@interface SCFloatingDockManager : NSObject
- (NSInteger)hostOrientation;
- (UIView *)hostRootView;
- (NSDictionary *)sc_targetFramesForSide:(NSInteger)side;
- (void)sc_layoutSide:(NSInteger)side animated:(BOOL)animated completion:(void (^)(void))completion;
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (void)sc_restoreAllDockedSessionsAnimated:(BOOL)animated;
@end

@interface SCFloatingContainerView : NSObject
- (void)sc_handleDockTap:(id)gesture;
- (void)sc_layoutExternalInteractionRegions;
- (NSArray *)cornerResizeTouchRegions;
- (id)delegate;
@end

// 自建 tap 手势的 target
@interface SCDockTapProxy : NSObject
- (void)sc_cornerTap:(UITapGestureRecognizer *)gesture;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);
static BOOL (*orig_dockSession)(id, SEL, id, NSInteger);
static NSInteger (*orig_activeHostOrientation)(id, SEL);
static void (*orig_orientationDidChange)(id, SEL, NSInteger, double);
static void (*orig_restoreAllDocked)(id, SEL, BOOL);
static NSDictionary *(*orig_targetFramesForSide)(id, SEL, NSInteger);
static void (*orig_handleDockTap)(id, SEL, id);
static void (*orig_layoutRegions)(id, SEL);

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

static BOOL sc_containerIsDocked(id container) {
    BOOL docked = NO;
    @try {
        if ([container respondsToSelector:@selector(isDocked)]) {
            docked = ((BOOL (*)(id, SEL))objc_msgSend)(container, @selector(isDocked));
        }
    } @catch (__unused NSException *e) {}
    return docked;
}

// 把「某个容器 + 角编号」落成侧贴。转发无效时按 session 直接 dock。
static BOOL sc_dockContainerFromCorner(id container, NSInteger corner, NSString *tag) {
    if (corner <= 0) return NO;
    if (sc_containerIsDocked(container)) {
        SC_LOG(@"%@: already docked, ignore", tag);
        return YES;
    }

    id delegate = nil;
    @try {
        if ([container respondsToSelector:@selector(delegate)]) delegate = [container delegate];
    } @catch (__unused NSException *e) {}
    SC_LOG(@"%@ corner=%ld delegate=%@", tag, (long)corner, [delegate class]);

    if ([delegate respondsToSelector:@selector(sc_floatingContainerView:didRequestDockFromCorner:)]) {
        @try {
            [(NSObject *)delegate sc_floatingContainerView:container didRequestDockFromCorner:corner];
        } @catch (NSException *e) {
            SC_LOG(@"%@ forward threw %@", tag, e.reason);
        }
    }
    if (sc_containerIsDocked(container)) {
        SC_LOG(@"%@ ok via forward", tag);
        return YES;
    }

    id session = nil;
    @try {
        if ([delegate respondsToSelector:@selector(sc_sessionForContainerView:)]) {
            session = [(NSObject *)delegate sc_sessionForContainerView:container];
        }
    } @catch (NSException *e) {
        SC_LOG(@"%@ session lookup threw %@", tag, e.reason);
    }
    if (!session && [delegate respondsToSelector:@selector(activeSession)]) {
        @try { session = [(SCFloatingSceneManager *)delegate activeSession]; }
        @catch (__unused NSException *e) {}
        SC_LOG(@"%@: no session for container, fall back to activeSession=%@", tag, [session class]);
    }
    if (!session) {
        SC_LOG(@"%@: no session at all", tag);
        return NO;
    }
    BOOL ok = NO;
    @try {
        ok = [(SCFloatingSceneManager *)delegate sc_dockSession:session fromCorner:corner];
    } @catch (NSException *e) {
        SC_LOG(@"%@ dock threw %@", tag, e.reason);
    }
    SC_LOG(@"%@ direct dock corner=%ld ok=%d", tag, (long)corner, ok);
    return ok;
}

#pragma mark - 横屏修复

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

    if (orientation < 3) {
        SC_LOG(@"dock rejected in portrait-%ld, leave as is", (long)orientation);
        return NO;
    }

    SC_LOG(@"dock rejected in landscape(%ld), retry with forced portrait", (long)orientation);
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

    id dock = nil;
    @try { dock = [(SCFloatingSceneManager *)self dockManager]; }
    @catch (__unused NSException *e) {}
    if ([dock respondsToSelector:@selector(sc_dockSession:fromCorner:)]) {
        @try {
            ok = [(SCFloatingDockManager *)dock sc_dockSession:session fromCorner:corner];
        } @catch (NSException *e) {
            SC_LOG(@"dockManager fallback threw %@", e.reason);
        }
        SC_LOG(@"landscape dock fallback via dockManager ok=%d", ok);
    }
    return ok;
}

#pragma mark - 自建四角 tap 手势

@implementation SCDockTapProxy

- (void)sc_cornerTap:(UITapGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (!view) return;

    CGPoint p = [gesture locationInView:view];
    CGRect b = view.bounds;
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    if (w <= 0 || h <= 0) return;

    CGFloat zone = MIN(MIN(w, h), 48.0);
    BOOL left = (p.x <= zone), right = (p.x >= w - zone);
    BOOL top = (p.y <= zone), bottom = (p.y >= h - zone);

    NSInteger corner = 0;
    if (top && left) corner = 1;
    else if (top && right) corner = 2;
    else if (bottom && left) corner = 3;
    else if (bottom && right) corner = 4;

    SC_LOG(@"own corner tap at %.0f,%.0f in %.0fx%.0f -> corner=%ld",
           p.x, p.y, w, h, (long)corner);
    if (corner == 0) return;

    sc_dockContainerFromCorner(view, corner, @"own corner dock");
}

@end

// 给容器装一个自己的 tap：原插件那套四角 region 在横屏下没被触发
// （真机日志里 sc_handleDockTap: 完全没进来），这里不再依赖它。
static void sc_installCornerTap(UIView *view) {
    if (!view) return;
    static SCDockTapProxy *proxy = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ proxy = [SCDockTapProxy new]; });

    if (objc_getAssociatedObject(view, "SCDockCornerTap")) return;
    objc_setAssociatedObject(view, "SCDockCornerTap", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:proxy
                                                                        action:@selector(sc_cornerTap:)];
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesEnded = NO;
    [view addGestureRecognizer:tap];
    SC_LOG(@"installed own corner tap on %@ bounds=%@", [view class], NSStringFromCGRect(view.bounds));
}

static void sc_walkForContainers(UIView *view, Class cls) {
    if (!view || !cls) return;
    if ([view isKindOfClass:cls]) {
        sc_installCornerTap(view);
    }
    for (UIView *sub in view.subviews) {
        sc_walkForContainers(sub, cls);
    }
}

static void sc_installCornerTapsEverywhere(SCFloatingSceneManager *manager) {
    id dock = nil;
    @try { dock = [(SCFloatingSceneManager *)manager dockManager]; }
    @catch (__unused NSException *e) {}
    UIView *root = nil;
    @try {
        if ([dock respondsToSelector:@selector(hostRootView)]) {
            root = [(SCFloatingDockManager *)dock hostRootView];
        }
    } @catch (__unused NSException *e) {}
    if (!root) {
        SC_LOG(@"own corner tap: hostRootView nil, skip");
        return;
    }
    sc_walkForContainers(root, objc_getClass("SCFloatingContainerView"));
}

#pragma mark - 横屏保留侧贴

static void hook_orientationDidChange(id self, SEL _cmd, NSInteger orientation, double duration) {
    sc_inOrientationChange = YES;
    @try {
        orig_orientationDidChange(self, _cmd, orientation, duration);
    } @finally {
        sc_inOrientationChange = NO;
    }
    SC_LOG(@"orientation change -> %ld done", (long)orientation);

    if (orientation >= 3) {
        id dock = nil;
        @try { dock = [(SCFloatingSceneManager *)self dockManager]; }
        @catch (__unused NSException *e) {}
        SCFloatingSceneManager *mgr = (SCFloatingSceneManager *)self;
        for (NSNumber *delay in @[@0.1, @0.4]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([delay doubleValue] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    for (NSInteger side = 1; side <= 2; side++) {
                        @try {
                            if ([dock respondsToSelector:@selector(sc_layoutSide:animated:completion:)]) {
                                [(SCFloatingDockManager *)dock sc_layoutSide:side animated:NO completion:nil];
                            }
                        } @catch (NSException *e) {
                            SC_LOG(@"landscape relayout side=%ld threw %@", (long)side, e.reason);
                        }
                    }
                    sc_installCornerTapsEverywhere(mgr);
                    SC_LOG(@"landscape relayout done");
                }
            });
        }
    }
}

static void hook_restoreAllDocked(id self, SEL _cmd, BOOL animated) {
    if (sc_inOrientationChange) {
        NSInteger host = 0;
        @try {
            if ([self respondsToSelector:@selector(hostOrientation)]) {
                host = [(SCFloatingDockManager *)self hostOrientation];
            }
        } @catch (__unused NSException *e) {}

        if (host >= 3) {
            SC_LOG(@"landscape entry: keep docked records (skip restoreAllDockedSessionsAnimated:)");
            return;
        }
    }
    orig_restoreAllDocked(self, _cmd, animated);
}

#pragma mark - 横屏缩小卡片

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
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("LandscapeDockScale"),
                                                    CFSTR("com.voring.screencoredock"));
    CGFloat s = 0.5;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            s = [(__bridge NSNumber *)v doubleValue];
        }
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
        SC_LOG(@"landscape frames side=%ld scale=%.2f %@ -> %@", (long)side, scale,
               NSStringFromCGRect(old), NSStringFromCGRect(nr));
    }
    return out;
}

#pragma mark - 原来的横屏点角 hook（保留作对照）

static void hook_handleDockTap(id self, SEL _cmd, id gesture) {
    UIView *superview = nil;
    @try { superview = [self superview]; }
    @catch (__unused NSException *e) {}

    if (!superview || CGRectGetWidth(superview.bounds) <= CGRectGetHeight(superview.bounds)) {
        if (orig_handleDockTap) orig_handleDockTap(self, _cmd, gesture);
        return;
    }

    SC_LOG(@"landscape dock tap enter, superview=%@", NSStringFromCGRect(superview.bounds));

    NSInteger corner = 0;
    @try {
        UIView *tapView = (UIView *)((id (*)(id, SEL))objc_msgSend)(gesture, @selector(view));
        if ([tapView respondsToSelector:@selector(tag)]) {
            corner = ((NSInteger (*)(id, SEL))objc_msgSend)(tapView, @selector(tag));
        }
    } @catch (__unused NSException *e) {}

    sc_dockContainerFromCorner(self, corner, @"landscape dock tap");
}

// 记录四角 region 的实际位置，用于核对横屏下是否被布局到容器外/不可点
static void hook_layoutRegions(id self, SEL _cmd) {
    orig_layoutRegions(self, _cmd);
    @try {
        NSArray *regions = [(SCFloatingContainerView *)self cornerResizeTouchRegions];
        if (regions.count == 0) {
            SC_LOG(@"regions layout: none");
            return;
        }
        NSMutableString *buf = [NSMutableString string];
        for (UIView *v in regions) {
            if (![v isKindOfClass:[UIView class]]) continue;
            [buf appendFormat:@"[tag=%ld %@ hit=%d] ", (long)v.tag,
             NSStringFromCGRect(v.frame), (int)v.isUserInteractionEnabled];
        }
        SC_LOG(@"regions layout: container=%@ %@", NSStringFromCGRect(((UIView *)self).bounds), buf);
    } @catch (NSException *e) {
        SC_LOG(@"regions layout log threw %@", e.reason);
    }
}

#pragma mark - 入口

static void sc_dockSessionIfPossible(SCFloatingSceneManager *manager) {
    id session = [manager activeSession];
    if (!session) {
        SC_LOG(@"activeSession == nil, skip dock");
        return;
    }

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
    if (!result) {
        SC_LOG(@"open returned NO, skip dock");
        return result;
    }

    @autoreleasepool {
        sc_dockSessionIfPossible((SCFloatingSceneManager *)self);
        SCFloatingSceneManager *mgr = (SCFloatingSceneManager *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sc_installCornerTapsEverywhere(mgr);
        });
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

    Class dockCls = objc_getClass("SCFloatingDockManager");
    if (dockCls && [dockCls instancesRespondToSelector:@selector(sc_targetFramesForSide:)]) {
        MSHookMessageEx(dockCls,
                        @selector(sc_targetFramesForSide:),
                        (IMP)hook_targetFramesForSide,
                        (IMP *)&orig_targetFramesForSide);
    }
    if (dockCls && [dockCls instancesRespondToSelector:@selector(sc_restoreAllDockedSessionsAnimated:)]) {
        MSHookMessageEx(dockCls,
                        @selector(sc_restoreAllDockedSessionsAnimated:),
                        (IMP)hook_restoreAllDocked,
                        (IMP *)&orig_restoreAllDocked);
    }

    Class containerCls = objc_getClass("SCFloatingContainerView");
    if (containerCls) {
        if ([containerCls instancesRespondToSelector:@selector(sc_handleDockTap:)]) {
            MSHookMessageEx(containerCls,
                            @selector(sc_handleDockTap:),
                            (IMP)hook_handleDockTap,
                            (IMP *)&orig_handleDockTap);
            SC_LOG(@"hooked sc_handleDockTap: on SCFloatingContainerView");
        }
        if ([containerCls instancesRespondToSelector:@selector(sc_layoutExternalInteractionRegions)]) {
            MSHookMessageEx(containerCls,
                            @selector(sc_layoutExternalInteractionRegions),
                            (IMP)hook_layoutRegions,
                            (IMP *)&orig_layoutRegions);
            SC_LOG(@"hooked sc_layoutExternalInteractionRegions");
        }
    } else {
        SC_LOG(@"SCFloatingContainerView not found, container hooks skipped");
    }

    SC_LOG(@"hooked (open + dockSession + orientation + restoreAllDocked + targetFrames + dockTap + regions)");
}

%ctor {
    @autoreleasepool {
        SC_LOG(@"v0.2.6 loaded in %@", [[NSProcessInfo processInfo] processName]);
        installHook(0);
    }
}
