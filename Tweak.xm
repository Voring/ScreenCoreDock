//
//  Tweak.xm
//  ScreenCoreDock  v0.2.5
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
//  v0.2.0：横屏卡片过大，按 0.5 缩放并重排
//  v0.2.1：横屏可点四角进侧贴；横屏左右间距对齐
//  v0.2.2：修安全模式 —— 不再在初始化时遍历全类表，改为按类名取 SCFloatingContainerView
//  v0.2.3：横屏点角补 session 兜底；顶部间距缩到 1/4
//  v0.2.4：点角取 session 失败时再萺 activeSession
//  v0.2.5：日志落盘（/var/mobile/Library/Logs/ScreenCoreDock.log），免 SSH 取证
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
//    这只影响下次旋转回来时的还原位置,不影响当次侧贴。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define SC_DOMAIN CFSTR("com.susudear.screencore")

// 同时写文件，方便在没有 SSH 的情况下用 Filza 直接看
// 优先 /var/mobile/Library/Logs/ScreenCoreDock.log，不可写则退回 /tmp/ScreenCoreDock.log
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

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);
static BOOL (*orig_dockSession)(id, SEL, id, NSInteger);
static NSInteger (*orig_activeHostOrientation)(id, SEL);
static void (*orig_orientationDidChange)(id, SEL, NSInteger, double);
static void (*orig_restoreAllDocked)(id, SEL, BOOL);
static NSDictionary *(*orig_targetFramesForSide)(id, SEL, NSInteger);
static void (*orig_handleDockTap)(id, SEL, id);

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

#pragma mark - 横屏点角落进侧贴

static void hook_handleDockTap(id self, SEL _cmd, id gesture) {
    UIView *superview = nil;
    @try { superview = [self superview]; }
    @catch (__unused NSException *e) {}

    if (!superview || CGRectGetWidth(superview.bounds) <= CGRectGetHeight(superview.bounds)) {
        if (orig_handleDockTap) orig_handleDockTap(self, _cmd, gesture);
        return;
    }

    SC_LOG(@"landscape dock tap enter, superview=%@", NSStringFromCGRect(superview.bounds));

    BOOL docked = NO;
    @try {
        if ([self respondsToSelector:@selector(isDocked)]) {
            docked = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isDocked));
        }
    } @catch (__unused NSException *e) {}
    if (docked) {
        SC_LOG(@"landscape dock tap: already docked, ignore");
        return;
    }

    id delegate = nil;
    @try {
        if ([self respondsToSelector:@selector(delegate)]) delegate = [self delegate];
    } @catch (__unused NSException *e) {}

    NSInteger corner = 0;
    @try {
        UIView *tapView = (UIView *)((id (*)(id, SEL))objc_msgSend)(gesture, @selector(view));
        if ([tapView respondsToSelector:@selector(tag)]) {
            corner = ((NSInteger (*)(id, SEL))objc_msgSend)(tapView, @selector(tag));
        }
    } @catch (__unused NSException *e) {}
    SC_LOG(@"landscape dock tap corner=%ld delegate=%@", (long)corner, [delegate class]);
    if (corner <= 0) return;

    if ([delegate respondsToSelector:@selector(sc_floatingContainerView:didRequestDockFromCorner:)]) {
        @try {
            [(NSObject *)delegate sc_floatingContainerView:self didRequestDockFromCorner:corner];
        } @catch (NSException *e) {
            SC_LOG(@"landscape dock tap forward threw %@", e.reason);
        }
    }

    BOOL now = NO;
    @try {
        if ([self respondsToSelector:@selector(isDocked)]) {
            now = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(isDocked));
        }
    } @catch (__unused NSException *e) {}
    if (now) {
        SC_LOG(@"landscape dock tap ok via forward");
        return;
    }

    id session = nil;
    @try {
        if ([delegate respondsToSelector:@selector(sc_sessionForContainerView:)]) {
            session = [(NSObject *)delegate sc_sessionForContainerView:self];
        }
    } @catch (NSException *e) {
        SC_LOG(@"landscape dock tap session lookup threw %@", e.reason);
    }
    if (!session && [delegate respondsToSelector:@selector(activeSession)]) {
        @try { session = [(SCFloatingSceneManager *)delegate activeSession]; }
        @catch (__unused NSException *e) {}
        SC_LOG(@"landscape dock tap: container has no session, fall back to activeSession=%@", [session class]);
    }
    if (!session) {
        SC_LOG(@"landscape dock tap: no session at all");
        return;
    }
    BOOL ok = NO;
    @try {
        ok = [(SCFloatingSceneManager *)delegate sc_dockSession:session fromCorner:corner];
    } @catch (NSException *e) {
        SC_LOG(@"landscape dock tap dock threw %@", e.reason);
    }
    SC_LOG(@"landscape dock tap direct dock corner=%ld ok=%d", (long)corner, ok);
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
    if (containerCls && [containerCls instancesRespondToSelector:@selector(sc_handleDockTap:)]) {
        MSHookMessageEx(containerCls,
                        @selector(sc_handleDockTap:),
                        (IMP)hook_handleDockTap,
                        (IMP *)&orig_handleDockTap);
        SC_LOG(@"hooked sc_handleDockTap: on SCFloatingContainerView");
    } else {
        SC_LOG(@"SCFloatingContainerView not found, dock tap hook skipped");
    }

    SC_LOG(@"hooked (open + dockSession + orientation + restoreAllDocked + targetFrames + dockTap)");
}

%ctor {
    @autoreleasepool {
        SC_LOG(@"v0.2.5 loaded in %@", [[NSProcessInfo processInfo] processName]);
        installHook(0);
    }
}
