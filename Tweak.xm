//
//  Tweak.xm
//  ScreenCoreDock
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」
//  (system-tool:fullscreen-to-screencore-split)
//  由「前台应用 -> 普通分屏浮窗」改为「前台应用 -> 侧贴浮窗(贴在屏幕两侧的小卡片)」。
//
//  逆向依据（ScreenCore.dylib arm64 切片，未滑动虚拟地址，详见 README.md）：
//    _SCFullscreenToSplitToolPerform            0x113a4
//      -> -[SCFloatingSceneManager sc_openFrontmostApplicationAsSplitFromSourceRect:]  0x48eb8
//         -> -[SCFloatingSceneManager sc_openSplitForBundleIdentifier:presentationSourceRect:]  0x46cf4
//            -> ... 0x47f60 (创建 SCFloatingSceneSession 并按 normalFrame 呈现)
//  该路径不会调用任何 dock 逻辑，因此窗口落地为「分屏浮窗」(居中大窗口)。
//  本 tweak 在原方法返回后取 activeSession，补一次 dock，使其落成「侧贴浮窗」。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define SC_DOMAIN CFSTR("com.susudear.screencore")
#define SC_LOG(fmt, ...) NSLog(@"[ScreenCoreDock] " fmt, ##__VA_ARGS__)

typedef id (*ObjcMsgSendId)(id, SEL);
typedef BOOL (*DockFn)(id, SEL, id, NSInteger);
typedef BOOL (*DockSingleFn)(id, SEL, id);

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);

static NSInteger sc_defaultDockCorner(void) {
    // 与插件自身 sc_dockSessionForSingleActiveWindow: 的取值一致：
    // splitDefaultDockSide == 1 -> corner 2，否则 corner 1（左侧）
    NSNumber *side = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"), SC_DOMAIN);
    if (![side respondsToSelector:@selector(integerValue)]) return 1;
    return ([side integerValue] == 1) ? 2 : 1;
}

static void sc_dockSessionIfPossible(id manager) {
    id session = ((ObjcMsgSendId)objc_msgSend)(manager, @selector(activeSession));
    if (!session) {
        SC_LOG(@"activeSession == nil, skip dock");
        return;
    }

    NSInteger corner = sc_defaultDockCorner();
    BOOL docked = ((DockFn)objc_msgSend)(manager,
                                        @selector(sc_dockSession:fromCorner:),
                                        session, corner);
    if (!docked) {
        // 兜底：走插件自身的「单窗口侧贴」封装（内部会再判定 isLiveSession / isSessionDocked）
        docked = ((DockSingleFn)objc_msgSend)(manager,
                                             @selector(sc_dockSessionForSingleActiveWindow:),
                                             session);
    }
    SC_LOG(@"dock session=%@ corner=%ld ok=%d", session, (long)corner, docked);
}

static BOOL hook_openFrontmostAsSplit(id self, SEL _cmd, CGRect rect) {
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
    if (!result) return result;

    @autoreleasepool {
        sc_dockSessionIfPossible(self);
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
    SC_LOG(@"hooked -[SCFloatingSceneManager sc_openFrontmostApplicationAsSplitFromSourceRect:]");
}

%ctor {
    @autoreleasepool {
        installHook(0);
    }
}
