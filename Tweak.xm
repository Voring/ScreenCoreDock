//
//  Tweak.xm
//  ScreenCoreDock  v0.3.5
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」
//  (system-tool:fullscreen-to-screencore-split)
//  由「前台应用 -> 分屏浮窗（居中大窗口）」改为「前台应用 -> 侧贴浮窗（贴屏幕两侧的小卡片）」。
//
//  基线（v0.1.0）：hook -[SCFloatingSceneManager sc_openFrontmostApplicationAsSplitFromSourceRect:]（0x48eb8）
//    原方法返回后取 activeSession 调 -sc_dockSession:fromCorner:；
//    失败再走 -sc_dockSessionForSingleActiveWindow:。
//
//  保留的横屏能力：
//    v0.1.8  放开 -sc_dockSession:fromCorner:（0x463ac）的方向守卫（0x463e4 只接受 1/2）；
//    v0.1.9  转横屏时 -sc_restoreAllDockedSessionsAnimated:（0x42ca8 尾部 0x42ee0）
//            不再把所有已侧贴的 session 强制收回；
//    v0.2.0  横屏卡片过大 -> 按 0.5 缩放 + 自上而下紧凑重排（LandscapeDockScale）；
//    v0.2.1  横屏左右间距对齐（左侧照抄右侧那个视觉间距）；
//    v0.2.3  横屏顶部间距缩到 1/4。
//
//  v0.3.0 移除（按需求推翻，永不再装）：
//    - 浮窗四角的一切监听器：原 sc_handleDockTap: hook、自建 UITapGestureRecognizer、
//      sc_layoutExternalInteractionRegions 诊断 hook；
//    - 所有「横屏点角转侧贴」的兜底链路（delegate 转发 / session 兜底 / activeSession 兜底）。
//    横屏下已存在的侧贴保持不动，位置也按上面的间距规则；但点四角不再有任何行为。
//
//  v0.3.1 新需求：浮窗左侧手势区（区域的 accessibilityIdentifier 是
//    "ScreenCore.Split.LeftMoveFullscreen"）原本绑的是 sc_handleFullscreenTap:
//    （转全屏），改成与右侧/下侧一致 -> sc_handleCloseTap:（关闭浮窗）。
//    顶部 "ScreenCore.Split.TopMoveFullscreen" 不动，仍为全屏。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <string.h>

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
- (BOOL)sc_openFrontmostApplicationAsSplitFromSourceRect:(CGRect)rect;
- (id)activeSession;
- (id)dockManager;
- (NSInteger)activeHostOrientation;   // 1 竖屏 / 2 倒竖屏 / 3、4 横屏
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (BOOL)sc_dockSessionForSingleActiveWindow:(id)session;
- (void)sc_closeSession:(id)session animated:(BOOL)animated;   // 0x4b044
- (void)sc_closeAllSessions;                                // 0x4addc
@end

@interface SCFloatingSceneManager (Orientation)
- (void)sc_activeHostOrientationDidChange:(NSInteger)orientation duration:(double)duration;
@end

// 左侧手势区改关闭：这两个 action 在 0x34628 安装区域时绑定
//   Top/Left   -> 0xab090 -> sc_handleFullscreenTap:（0x385b8）
//   Bottom/Right -> 0xab098 -> sc_handleCloseTap:（0x3853c）
@interface SCFloatingContainerView : NSObject
- (void)sc_handleFullscreenTap:(id)gesture;
- (void)sc_handleCloseTap:(id)gesture;
@end

@interface SCFloatingDockManager : NSObject
- (NSInteger)hostOrientation;
- (UIView *)hostRootView;
- (NSDictionary *)sc_targetFramesForSide:(NSInteger)side;
- (void)sc_layoutSide:(NSInteger)side animated:(BOOL)animated completion:(void (^)(void))completion;
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (void)sc_restoreAllDockedSessionsAnimated:(BOOL)animated;
- (void)sc_undockSession:(id)session animated:(BOOL)animated;   // 0x3ce94
- (void)sc_restoreRecordToNormalFrame:(id)record animated:(BOOL)animated completion:(void (^)(void))completion; // 0x3c7e0
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);
static BOOL (*orig_dockSession)(id, SEL, id, NSInteger);
static NSInteger (*orig_activeHostOrientation)(id, SEL);
static void (*orig_orientationDidChange)(id, SEL, NSInteger, double);
static void (*orig_restoreAllDocked)(id, SEL, BOOL);
static NSDictionary *(*orig_targetFramesForSide)(id, SEL, NSInteger);
static void (*orig_handleFullscreenTap)(id, SEL, id);
static void (*orig_undockSession)(id, SEL, id, BOOL);
static void (*orig_closeSession)(id, SEL, id, BOOL);
static void (*orig_closeAllSessions)(id, SEL);
static void (*orig_restoreRecord)(id, SEL, id, BOOL, void (^)(void));

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

#pragma mark - 横屏放开 dock 入口（v0.1.8）

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

    // 兜底：直接走 DockManager 层（该层无方向守卫）
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

#pragma mark - 左侧手势区改为关闭浮窗（v0.3.1）

static void hook_handleFullscreenTap(id self, SEL _cmd, id gesture) {
    UIView *region = nil;
    @try { region = [gesture view]; }
    @catch (__unused NSException *e) {}

    NSString *ident = nil;
    @try { ident = [region accessibilityIdentifier]; }
    @catch (__unused NSException *e) {}

    if (ident && [ident isEqualToString:@"ScreenCore.Split.LeftMoveFullscreen"]) {
        SC_LOG(@"left gesture region tapped, close floating window instead of fullscreen");
        [(SCFloatingContainerView *)self sc_handleCloseTap:gesture];
        return;
    }

    if (orig_handleFullscreenTap) orig_handleFullscreenTap(self, _cmd, gesture);
}

#pragma mark - 通知中心下拉时保留侧贴（v0.3.5）

// v0.3.3 教训：启动早期调 +[SBCoverSheetPresentationManager sharedInstance] 会 SIGABRT。
// v0.3.4 教训：即便延迟 5 秒，只要拿到的东西不是合法类对象，NSStringFromClass 也能崩
//   （崩溃帧：objc_class::demangledName -> NSStringFromClass -> ScreenCoreDock+0x6978）。
// 本版彻底不碰 SBCoverSheetPresentationManager，改用「窗口类名」判断通知中心是否在场，
// 只用 object_getClassName（不构造 NSString、不查类），不会触发任何单例初始化。

static BOOL sc_windowClassNameContains(const char *needle) {
    NSArray *windows = nil;
    @try {
        windows = [UIApplication sharedApplication].windows;
    } @catch (__unused NSException *e) {}
    for (UIWindow *w in windows) {
        const char *n = object_getClassName(w);
        if (n && strstr(n, needle)) return YES;
    }
    return NO;
}

static BOOL sc_coverSheetPresented(void) {
    // 通知中心 / CoverSheet 在 SpringBoard 自己的窗口层里
    return sc_windowClassNameContains("CoverSheet")
        || sc_windowClassNameContains("NotificationCenter");
}

static void sc_dumpCoverSheetDiagnostics(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray *windows = nil;
        @try { windows = [UIApplication sharedApplication].windows; }
        @catch (__unused NSException *e) {}
        NSMutableString *names = [NSMutableString string];
        for (UIWindow *w in windows) {
            const char *n = object_getClassName(w);
            [names appendFormat:@"%s ", n ? n : "?"];
        }
        SC_LOG(@"windows at 5s: %@", names);
        SC_LOG(@"coverSheet by window name = %d", (int)sc_coverSheetPresented());
    });
}

static void hook_undockSession(id self, SEL _cmd, id session, BOOL animated) {
    if (sc_coverSheetPresented()) {
        SC_LOG(@"notification center shown: skip undockSession:%s", object_getClassName(session));
        return;
    }
    orig_undockSession(self, _cmd, session, animated);
}

static void hook_closeSessionAnimated(id self, SEL _cmd, id session, BOOL animated) {
    BOOL shown = sc_coverSheetPresented();
    SC_LOG(@"sc_closeSession:animated: called (coverSheet=%d) session=%s",
           (int)shown, object_getClassName(session));
    if (shown) {
        SC_LOG(@"notification center shown: skip closeSession:%s", object_getClassName(session));
        return;
    }
    orig_closeSession(self, _cmd, session, animated);
}

static void hook_closeAllSessions(id self, SEL _cmd) {
    if (sc_coverSheetPresented()) {
        SC_LOG(@"notification center shown: skip closeAllSessions");
        return;
    }
    orig_closeAllSessions(self, _cmd);
}

static void hook_restoreRecord(id self, SEL _cmd, id record, BOOL animated,
                                void (^completion)(void)) {
    SC_LOG(@"restoreRecordToNormalFrame called (coverSheet=%d) record=%s",
           (int)sc_coverSheetPresented(), object_getClassName(record));
    orig_restoreRecord(self, _cmd, record, animated, completion);
}

#pragma mark - 横屏不强制收回侧贴（v0.1.9）+ 横屏重排

static void hook_orientationDidChange(id self, SEL _cmd, NSInteger orientation, double duration) {
    sc_inOrientationChange = YES;
    @try {
        orig_orientationDidChange(self, _cmd, orientation, duration);
    } @finally {
        sc_inOrientationChange = NO;
    }
    SC_LOG(@"orientation change -> %ld done", (long)orientation);

    // 转进横屏后补一次侧边布局，让 hook_targetFramesForSide 的缩放帧真正生效
    if (orientation >= 3) {
        id dock = nil;
        @try { dock = [(SCFloatingSceneManager *)self dockManager]; }
        @catch (__unused NSException *e) {}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
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
                SC_LOG(@"landscape relayout done");
            }
        });
    }
}

static void hook_restoreAllDocked(id self, SEL _cmd, BOOL animated) {
    if (sc_coverSheetPresented()) {
        SC_LOG(@"notification center shown: skip restoreAllDockedSessionsAnimated:");
        return;
    }
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

#pragma mark - 横屏卡片缩放与间距（v0.2.0 / v0.2.1 / v0.2.3）

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
    // 横屏左右间距：保持右侧那个视觉间距（8 + 缩掉的一半宽度），左侧照抄同一值。
    // 顶部只取该间距叠加状态栏高度的 1/4。
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
        SC_LOG(@"hooked sc_handleFullscreenTap: (left region -> close)");
    } else {
        SC_LOG(@"sc_handleFullscreenTap: hook skipped");
    }

    Class dockCls = objc_getClass("SCFloatingDockManager");
    if (dockCls && [dockCls instancesRespondToSelector:@selector(sc_targetFramesForSide:)]) {
        MSHookMessageEx(dockCls,
                        @selector(sc_targetFramesForSide:),
                        (IMP)hook_targetFramesForSide,
                        (IMP *)&orig_targetFramesForSide);
    }
    if (dockCls && [dockCls instancesRespondToSelector:@selector(sc_undockSession:animated:)]) {
        MSHookMessageEx(dockCls,
                        @selector(sc_undockSession:animated:),
                        (IMP)hook_undockSession,
                        (IMP *)&orig_undockSession);
        SC_LOG(@"hooked sc_undockSession:animated: (skip while cover sheet shown)");
    }
    if ([cls instancesRespondToSelector:@selector(sc_closeSession:animated:)]) {
        MSHookMessageEx(cls,
                        @selector(sc_closeSession:animated:),
                        (IMP)hook_closeSessionAnimated,
                        (IMP *)&orig_closeSession);
        SC_LOG(@"hooked sc_closeSession:animated: (skip while cover sheet shown)");
    }
    if ([cls instancesRespondToSelector:@selector(sc_closeAllSessions)]) {
        MSHookMessageEx(cls,
                        @selector(sc_closeAllSessions),
                        (IMP)hook_closeAllSessions,
                        (IMP *)&orig_closeAllSessions);
        SC_LOG(@"hooked sc_closeAllSessions");
    }
    if (dockCls && [dockCls instancesRespondToSelector:@selector(sc_restoreRecordToNormalFrame:animated:completion:)]) {
        MSHookMessageEx(dockCls,
                        @selector(sc_restoreRecordToNormalFrame:animated:completion:),
                        (IMP)hook_restoreRecord,
                        (IMP *)&orig_restoreRecord);
        SC_LOG(@"hooked sc_restoreRecordToNormalFrame:animated:completion:");
    }
    if (dockCls && [dockCls instancesRespondToSelector:@selector(sc_restoreAllDockedSessionsAnimated:)]) {
        MSHookMessageEx(dockCls,
                        @selector(sc_restoreAllDockedSessionsAnimated:),
                        (IMP)hook_restoreAllDocked,
                        (IMP *)&orig_restoreAllDocked);
    }

    sc_dumpCoverSheetDiagnostics();
    SC_LOG(@"hooked (open + dockSession + orientation + restoreAllDocked + targetFrames + leftRegionClose + keepOnCoverSheet v5)");
}

%ctor {
    @autoreleasepool {
        SC_LOG(@"v0.3.5 loaded in %@", [[NSProcessInfo processInfo] processName]);
        installHook(0);
    }
}
