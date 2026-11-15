//
//  Tweak.xm
//  ScreenCoreDock  v0.1.6
//
//  两个互斥模式，靠偏好开关切换（不写死在代码里）：
//
//    FreeFloatMode = 0（默认）  还原 v0.1.0 的「全屏转侧贴浮窗」：
//        打开后把会话停靠到侧边（displayState 1），也就是你原来 1.0 的效果。
//        v0.1.5 删掉了 dock 调用，导致这个功能失效，本版恢复。
//
//    FreeFloatMode = 1          自由浮窗：
//        打开后不留在 dock，改用插件自己的「还原普通帧」例程
//        -sc_restoreRecordToNormalFrame:animated:completion:（0x3c7e0），
//        它内部会 setDisplayState:3 并动画回 normalFrame，
//        普通浮窗（displayState 3）不受侧边槽位模型约束。
//        注意：这是「取消停靠」，不做贴边吸附，松手不会回侧边竖排。
//
//  已验证选择器（ScreenCore 2.0.5 arm64，未滑动地址）：
//    -sc_openFrontmostApplicationAsSplitFromSourceRect:      0x48eb8
//    -activeSession                                          0x65260(stub)
//    -dockManager                                            0x66880
//    -sc_dockSession:fromCorner:                             0x463ac
//    -sc_dockSessionForSingleActiveWindow:                   0x462e4
//    -sc_recordsForSide:                                     0x3a170
//    -sc_restoreRecordToNormalFrame:animated:completion:     0x3c7e0
//    -session（record 上）                                   0x6c920(stub)
//    -containerView                                          0x661e0
//    -displayState / -setDisplayState:                       0x66820 / 0x6d7a0(stub)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define SC_DOMAIN        CFSTR("com.susudear.screencore")
#define SC_TWEAK_DOMAIN  CFSTR("com.voring.screencoredock")
#define SC_PREF_KEY      CFSTR("FreeFloatMode")
#define SC_LOG(fmt, ...) NSLog(@"[ScreenCoreDock] " fmt, ##__VA_ARGS__)

@interface SCFloatingSceneManager : NSObject
- (BOOL)sc_openFrontmostApplicationAsSplitFromSourceRect:(CGRect)rect;
- (id)activeSession;
- (id)dockManager;
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (BOOL)sc_dockSessionForSingleActiveWindow:(id)session;
@end

@interface SCFloatingSceneSession : NSObject
- (id)containerView;
@end

@interface SCFloatingDockManager : NSObject
- (NSArray *)sc_recordsForSide:(NSInteger)side;
- (void)sc_restoreRecordToNormalFrame:(id)record
                            animated:(BOOL)animated
                          completion:(void (^)(void))completion;
@end

@interface SCFloatingDockRecord : NSObject
- (id)session;
@end

@interface SCFloatingContainer : NSObject
- (NSInteger)displayState;
- (void)setDisplayState:(NSInteger)state;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);

#pragma mark - 偏好

static BOOL sc_freeFloatMode(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(SC_PREF_KEY, SC_TWEAK_DOMAIN);
    BOOL on = NO;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)v);
        } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            on = [(__bridge NSNumber *)v boolValue];
        } else if (CFGetTypeID(v) == CFStringGetTypeID()) {
            on = [(__bridge NSString *)v boolValue];
        }
        CFRelease(v);
    }
    return on;
}

static NSInteger sc_defaultDockCorner(void) {
    NSNumber *side = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"), SC_DOMAIN);
    if (![side isKindOfClass:[NSNumber class]]) return 1;
    return ([side integerValue] == 1) ? 2 : 1;
}

#pragma mark - 模式 0：停靠到侧边（还原 v0.1.0）

static void sc_dockSession(SCFloatingSceneManager *manager) {
    id session = [manager activeSession];
    if (!session) {
        SC_LOG(@"dock path: activeSession == nil, skip");
        return;
    }
    NSInteger corner = sc_defaultDockCorner();
    BOOL ok = NO;
    @try {
        if ([manager respondsToSelector:@selector(sc_dockSession:fromCorner:)]) {
            ok = [manager sc_dockSession:session fromCorner:corner];
        }
    } @catch (NSException *e) {
        SC_LOG(@"dock path: sc_dockSession threw %@", e.reason);
    }
    if (!ok) {
        @try {
            if ([manager respondsToSelector:@selector(sc_dockSessionForSingleActiveWindow:)]) {
                ok = [manager sc_dockSessionForSingleActiveWindow:session];
            }
        } @catch (NSException *e) {
            SC_LOG(@"dock path: singleActiveWindow threw %@", e.reason);
        }
    }
    SC_LOG(@"dock path: corner=%ld ok=%d session=%p", (long)corner, ok, session);
}

#pragma mark - 模式 1：取消停靠 -> 普通浮窗

static void sc_tryRestoreToNormalFloating(SCFloatingSceneManager *manager, id session) {
    id dock = nil;
    @try {
        if ([manager respondsToSelector:@selector(dockManager)]) dock = [manager dockManager];
    } @catch (NSException *e) {
        SC_LOG(@"free path: dockManager threw %@", e.reason);
    }
    if (!dock) {
        SC_LOG(@"free path: dockManager == nil");
    }

    NSInteger restored = 0;
    if ([dock respondsToSelector:@selector(sc_recordsForSide:)] &&
        [dock respondsToSelector:@selector(sc_restoreRecordToNormalFrame:animated:completion:)]) {
        for (NSInteger side = 1; side <= 2; side++) {
            NSArray *records = nil;
            @try { records = [(SCFloatingDockManager *)dock sc_recordsForSide:side]; }
            @catch (NSException *e) { SC_LOG(@"free path: recordsForSide:%ld threw %@", (long)side, e.reason); }

            for (id record in records) {
                id owner = nil;
                @try { owner = [(SCFloatingDockRecord *)record session]; }
                @catch (__unused NSException *e) {}
                if (owner != session) continue;

                @try {
                    [(SCFloatingDockManager *)dock sc_restoreRecordToNormalFrame:record
                                                                        animated:NO
                                                                      completion:nil];
                    restored++;
                    SC_LOG(@"free path: restored record %p (side=%ld)", record, (long)side);
                } @catch (NSException *e) {
                    SC_LOG(@"free path: restore threw %@", e.reason);
                }
            }
        }
    }

    // 兜底：直接把容器拉回普通浮窗状态
    SCFloatingContainer *container = nil;
    @try { container = [session containerView]; } @catch (__unused NSException *e) {}
    if (container && [container respondsToSelector:@selector(setDisplayState:)]) {
        NSInteger before = 0;
        @try { before = [container displayState]; } @catch (__unused NSException *e) {}
        @try {
            [container setDisplayState:3];
            SC_LOG(@"free path: displayState %ld -> 3 (restored=%ld)", (long)before, (long)restored);
        } @catch (NSException *e) {
            SC_LOG(@"free path: setDisplayState:3 threw %@", e.reason);
        }
    } else {
        SC_LOG(@"free path: no containerView (restored=%ld)", (long)restored);
    }
}

#pragma mark - 入口

static BOOL hook_openFrontmostAsSplit(id self, SEL _cmd, CGRect rect) {
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
    if (!result) {
        SC_LOG(@"open returned NO, nothing to do");
        return result;
    }

    SCFloatingSceneManager *manager = (SCFloatingSceneManager *)self;
    BOOL freeMode = sc_freeFloatMode();
    SC_LOG(@"open ok, mode=%s", freeMode ? "free-float(1)" : "dock(0)");

    if (!freeMode) {
        @autoreleasepool {
            sc_dockSession(manager);
        }
        return result;
    }

    // 停靠时才有的 record 列表，等一拍让 dock 状态落地再撤
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            id session = [manager activeSession];
            if (!session) {
                SC_LOG(@"free path: activeSession == nil");
                return;
            }
            sc_tryRestoreToNormalFloating(manager, session);
        }
    });
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
    SC_LOG(@"hooked (mode=%s)", sc_freeFloatMode() ? "free-float(1)" : "dock(0)");
}

%ctor {
    @autoreleasepool {
        installHook(0);
    }
}
