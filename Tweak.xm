//
//  Tweak.xm
//  ScreenCoreDock
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」
//  (system-tool:fullscreen-to-screencore-split) 打开的窗口，保持在原生普通浮窗状态，
//  不进入侧贴（dock）排列，从而沿用插件原生的自由拖动 / 缩放 / 记忆位置能力。
//
//  背景（逆向结论）：
//    - 侧贴 = containerView displayState 1；普通浮窗 = displayState 3。
//    - 原插件链路：_SCFullscreenToSplitToolPerform
//        -> -sc_openFrontmostApplicationAsSplitFromSourceRect: 0x48eb8
//        -> -sc_openSplitForBundleIdentifier:presentationSourceRect: 0x46cf4
//      我们之前在打开后额外调了 -sc_dockSession:fromCorner:，把会话切成 state 1 侧贴。
//    - 侧贴布局模型：record 坐标 = f(side, order)，松手必回槽位；
//      拖拽结束 -sc_moveDraggingRecord:toSide:center: 0x3e5e4
//        -> -sc_updateNormalizedYForOrder: 0x3e52c
//        -> -sc_layoutSide:animated:completion: 0x3b1fc
//        -> -sc_targetFramesForSide: 0x3a384
//        -> -sc_applyFrame:toRecord: 0x3ac70
//      这套模型在拖拽收尾和重排两层都会把位置拉回边缘，硬改槽位无法稳定自由摆放，
//      所以本版不再挂钩这套侧贴布局，只保证打开后是普通浮窗。
//
//  逆向依据（arm64 切片，未滑动虚拟地址）：
//    0x113a4  _SCFullscreenToSplitToolPerform
//    0x48eb8  -sc_openFrontmostApplicationAsSplitFromSourceRect:
//    0x46cf4  -sc_openSplitForBundleIdentifier:presentationSourceRect:
//    0x463ac  -sc_dockSession:fromCorner:        （内部 setDisplayState:1）
//    0x3c8d0  还原普通帧时 setDisplayState:3
//    0x38b3c  displayState / 0x38b4c setDisplayState:
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define SC_DOMAIN CFSTR("com.susudear.screencore")
#define SC_LOG(fmt, ...) NSLog(@"[ScreenCoreDock] " fmt, ##__VA_ARGS__)

@interface SCFloatingSceneManager : NSObject
- (BOOL)sc_openFrontmostApplicationAsSplitFromSourceRect:(CGRect)rect;
- (id)activeSession;
@end

@interface SCFloatingSession : NSObject
- (id)containerView;
@end

@interface SCFloatingContainer : NSObject
- (NSInteger)displayState;
- (void)setDisplayState:(NSInteger)state;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);

static BOOL hook_openFrontmostAsSplit(id self, SEL _cmd, CGRect rect) {
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
    if (!result) return result;

    @autoreleasepool {
        id session = [(SCFloatingSceneManager *)self activeSession];
        if (!session) {
            SC_LOG(@"activeSession == nil after open");
            return result;
        }
        SCFloatingContainer *container = nil;
        @try { container = [session containerView]; } @catch (__unused NSException *e) {}

        NSInteger before = 0;
        @try { before = [container displayState]; } @catch (__unused NSException *e) {}

        // 不做 dock：确保容器处于普通浮窗状态（state 3），不切到侧贴 state 1。
        if (container && [container respondsToSelector:@selector(setDisplayState:)]) {
            @try {
                [container setDisplayState:3];
                SC_LOG(@"session=%p container=%p displayState %ld -> 3 (normal floating)",
                       session, container, (long)before);
            } @catch (NSException *e) {
                SC_LOG(@"setDisplayState:3 failed: %@", e.reason);
            }
        } else {
            SC_LOG(@"session=%p no containerView/setDisplayState, state=%ld",
                   session, (long)before);
        }
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
    SC_LOG(@"hooked (normal floating, no dock)");
}

%ctor {
    @autoreleasepool {
        installHook(0);
    }
}
