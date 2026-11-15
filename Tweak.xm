//
//  Tweak.xm
//  ScreenCoreDock  v0.1.9
//
//  代码回退到 v0.1.0 初版：只有「打开分屏后补一次 dock」这一条逻辑，
//  去掉 v0.1.1~v0.1.7 的自由摆放 / FreeFloatMode / 帧表覆盖 / 收尾层 hook。
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」
//  (system-tool:fullscreen-to-screencore-split)
//  由「前台应用 -> 分屏浮窗（居中大窗口）」改为「前台应用 -> 侧贴浮窗（贴屏幕两侧的小卡片）」。
//
//  逆向依据（ScreenCore.dylib 2.0.5 arm64 切片，未滑动虚拟地址，详见 README.md）：
//    _SCFullscreenToSplitToolPerform            0x113a4
//      -> -[SCFloatingSceneManager sc_openFrontmostApplicationAsSplitFromSourceRect:]  0x48eb8
//         -> -[SCFloatingSceneManager sc_openSplitForBundleIdentifier:presentationSourceRect:]  0x46cf4
//            -> ... 0x47f60 （创建 SCFloatingSceneSession，按 normalFrame 呈现）
//  这条链路里没有任何 dock 调用，所以窗口必定是「分屏浮窗」。
//  本 tweak 在原方法返回后取 activeSession 补一次 dock，使其落成「侧贴浮窗」。
//
//  v0.1.8：横屏修复（放开 sc_dockSession:fromCorner: 的方向守卫）
//  v0.1.9：再解掉「转入横屏时强制收回全部侧贴」这一道限制
//
//    第二道限制在 -sc_activeHostOrientationDidChange:duration:（0x42ca8）末尾：
//
//        0x42ec0  cmp   x26, #1          ; x26 = 新方向 - 3
//        0x42ec4  b.hi  0x42eec          ; 非横屏跳过
//        0x42ee0  bl    sc_restoreAllDockedSessionsAnimated:   ; 横屏 -> 全部收回
//
//    也就是只要方向变成横屏(3/4)，dockManager 会把所有已侧贴的 session 全部
//    restore 回普通浮窗，结果就是「横屏不允许悬挂侧贴」。
//    v0.1.9 的修法：hook SCFloatingSceneManager -sc_activeHostOrientationDidChange:duration:
//    打一个「方向切换进行中」标记，再 hook SCFloatingDockManager
//    -sc_restoreAllDockedSessionsAnimated:，当标记为真且 hostOrientation >= 3 时放行保留。
//    手动「全部收回」等其它调用不在此期间，照常执行。
//
//  v0.1.8 细节：
//
//    -[SCFloatingSceneManager sc_dockSession:fromCorner:]（0x463ac）进函数后立刻
//    校验 host 方向：
//
//        0x463e0  bl    activeHostOrientation
//        0x463e4  sub   x8, x0, #1
//        0x463e8  cmp   x8, #1
//        0x463ec  b.hi  -> 0x46518      ; 直接 return NO
//
//    也就是只接受 1(竖屏) / 2(倒竖屏)，横屏(3/4)直接返回 NO，什么都不做。
//    而它下层的 DockManager 同名方法（0x3bde4）没有方向判断，只校验
//    normalFrame 是否合法（0x3b0a0：非 null、非空、宽高 > 1），通过就把
//    record 建出来、setFrame、addSubview、setDisplayState、setDocked。
//
//    所以横屏侧贴不了，卡点只在 manager 这一层的方向守卫。
//    修法：hook -sc_dockSession:fromCorner:，原方法返回 NO 且当前是横屏时，
//    临时把 activeHostOrientation 顶成 1（竖屏）后重入一次原方法，让插件自己
//    走完整的侧贴流程；仍失败则直接走 DockManager 层的同名方法兜底。
//
//    副作用说明：重入时 sc_saveFrame:forSession:forHostOrientation:contentOrientation:
//    会把当前帧按「竖屏」key 记下来，因此横屏下的记忆帧归到竖屏档位。
//    这只影响下次旋转回来时的还原位置，不影响当次侧贴。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define SC_DOMAIN CFSTR("com.susudear.screencore")
#define SC_LOG(fmt, ...) NSLog(@"[ScreenCoreDock] " fmt, ##__VA_ARGS__)

// 只做声明，不提供实现；运行时类由 ScreenCore.dylib 提供。
// corner：1 = 一侧，2 = 另一侧（插件内部 sc_dockSessionForSingleActiveWindow: 就是这么映射的）
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

@interface SCFloatingDockManager : NSObject
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (NSInteger)hostOrientation;
- (void)sc_restoreAllDockedSessionsAnimated:(BOOL)animated;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);
static BOOL (*orig_dockSession)(id, SEL, id, NSInteger);
static NSInteger (*orig_activeHostOrientation)(id, SEL);
static void (*orig_orientationDidChange)(id, SEL, NSInteger, double);
static void (*orig_restoreAllDocked)(id, SEL, BOOL);

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

    // 竖屏被拒说明是别的原因（session 不 live / 已 dock / 槽位满），不插手
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

    // 兜底：manager 层还有别的拦截时，直接走 DockManager 层（该层无方向守卫）
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

#pragma mark - 横屏保留侧贴

// 方向切换期间打标记，供 restoreAll 判断是不是「转入横屏」触发的强制收回
static void hook_orientationDidChange(id self, SEL _cmd, NSInteger orientation, double duration) {
    sc_inOrientationChange = YES;
    @try {
        orig_orientationDidChange(self, _cmd, orientation, duration);
    } @finally {
        sc_inOrientationChange = NO;
    }
    SC_LOG(@"orientation change -> %ld done", (long)orientation);
}

// 插件在转入横屏时会调它把全部侧贴收回（0x42ec0/0x42ee0），这里放行保留
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
        // 兜底：走插件自己的「单窗口侧贴」封装（内部会再判 isLiveSession / isSessionDocked）
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
        // ScreenCore.dylib 可能比本 tweak 后加载，短暂重试
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

    // 只有 manager 这一层有方向守卫，改它的返回值即可
    if ([cls instancesRespondToSelector:@selector(activeHostOrientation)]) {
        MSHookMessageEx(cls,
                        @selector(activeHostOrientation),
                        (IMP)hook_activeHostOrientation,
                        (IMP *)&orig_activeHostOrientation);
    }

    // 转入横屏时插件会强制收回全部侧贴，挂方向切换入口和收回方法
    if ([cls instancesRespondToSelector:@selector(sc_activeHostOrientationDidChange:duration:)]) {
        MSHookMessageEx(cls,
                        @selector(sc_activeHostOrientationDidChange:duration:),
                        (IMP)hook_orientationDidChange,
                        (IMP *)&orig_orientationDidChange);
    }

    Class dockCls = objc_getClass("SCFloatingDockManager");
    if (dockCls && [dockCls instancesRespondToSelector:@selector(sc_restoreAllDockedSessionsAnimated:)]) {
        MSHookMessageEx(dockCls,
                        @selector(sc_restoreAllDockedSessionsAnimated:),
                        (IMP)hook_restoreAllDocked,
                        (IMP *)&orig_restoreAllDocked);
    }

    SC_LOG(@"hooked (open + dockSession + activeHostOrientation + orientationChange + restoreAllDocked)");
}

%ctor {
    @autoreleasepool {
        installHook(0);
    }
}
