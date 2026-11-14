//
//  Tweak.xm
//  ScreenCoreDock
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」的产物，从「分屏浮窗」（居中大窗口）
//  改为「小尺寸悬浮窗」。
//
//  两种落地模式（编译期开关）：
//    SC_DOCK_MODE 0 = 小尺寸普通浮窗：可自由移动 / 缩放（默认）
//    SC_DOCK_MODE 1 = 侧贴浮窗：贴边小卡片（位置由 dockManager 按 side+顺序排布，不能自由摆放）
//
//  逆向依据（arm64 切片，未滑动地址）：
//    _SCFullscreenToSplitToolPerform 0x113a4 -> 0x48eb8 -> 0x46cf4 -> 0x47f60
//    frame 来源：sc_rememberedFrameForTargetIdentifier:... 0x43f1c / sc_defaultContainerFrameForReferenceSize:hostBounds: 0x43c1c
//    侧贴：sc_dockSession:fromCorner: 0x463ac / 布局 sc_targetFramesForSide: 0x3a384
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#ifndef SC_DOCK_MODE
#define SC_DOCK_MODE 0
#endif

#ifndef SC_FLOAT_WIDTH_RATIO
#define SC_FLOAT_WIDTH_RATIO 0.45
#endif
#ifndef SC_FLOAT_MAX_HEIGHT_RATIO
#define SC_FLOAT_MAX_HEIGHT_RATIO 0.70
#endif

#define SC_DOMAIN CFSTR("com.susudear.screencore")
#define SC_LOG(fmt, ...) NSLog(@"[ScreenCoreDock] " fmt, ##__VA_ARGS__)

@interface SCFloatingSceneManager : NSObject
- (BOOL)sc_openFrontmostApplicationAsSplitFromSourceRect:(CGRect)rect;
- (id)activeSession;
- (CGRect)sc_hostBoundsForActiveOrientation;
- (CGRect)sc_defaultContainerFrameForReferenceSize:(CGSize)referenceSize hostBounds:(CGRect)hostBounds;
- (CGRect)sc_rememberedFrameForTargetIdentifier:(id)target
                                   hostLandscape:(BOOL)hostLandscape
                                contentLandscape:(BOOL)contentLandscape
                                   referenceSize:(CGSize)referenceSize
                                        fallback:(CGRect)fallback;
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (BOOL)sc_dockSessionForSingleActiveWindow:(id)session;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);
static CGRect (*orig_defaultContainerFrame)(id, SEL, CGSize, CGRect);
static CGRect (*orig_rememberedFrame)(id, SEL, id, BOOL, BOOL, CGSize, CGRect);

// 只在「本工具」调用期间收缩，避免影响 ARC / 手势 / URL 等其它入口
static BOOL gInToolCall = NO;
static BOOL gShrunk = NO;

static NSInteger sc_defaultDockCorner(void) {
    NSNumber *side = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"), SC_DOMAIN);
    if (![side isKindOfClass:[NSNumber class]]) return 1;
    return ([side integerValue] == 1) ? 2 : 1;
}

/// 依据原 frame 的长宽比，算一个居中的小窗口
static CGRect sc_smallFrameForFrame(CGRect original, CGRect host) {
    if (host.size.width < 1 || host.size.height < 1) {
        host = [UIScreen mainScreen].bounds;
    }
    CGFloat ratio = (original.size.width > 1) ? (original.size.height / original.size.width) : 1.0;
    if (ratio < 0.5 || ratio > 2.5) ratio = host.size.height / host.size.width;

    CGFloat w = host.size.width * SC_FLOAT_WIDTH_RATIO;
    CGFloat h = w * ratio;
    CGFloat maxH = host.size.height * SC_FLOAT_MAX_HEIGHT_RATIO;
    if (h > maxH) {
        h = maxH;
        w = h / ratio;
    }
    CGFloat minW = 120.0;
    if (w < minW) {
        w = minW;
        h = w * ratio;
    }

    CGFloat x = CGRectGetMidX(host) - w / 2.0;
    CGFloat y = CGRectGetMidY(host) - h / 2.0;
    return CGRectMake(x, y, w, h);
}

/// 保证每次工具调用只收缩一次（默认 frame 与记忆 frame 两个入口都可能被走到）
static CGRect sc_maybeShrink(id manager, CGRect frame) {
    if (!gInToolCall || gShrunk) return frame;
    gShrunk = YES;

    CGRect host = CGRectNull;
    if ([manager respondsToSelector:@selector(sc_hostBoundsForActiveOrientation)]) {
        host = [manager sc_hostBoundsForActiveOrientation];
    }
    if (CGRectIsEmpty(host) || host.size.width < 1) {
        host = [UIScreen mainScreen].bounds;
    }

    CGRect small = sc_smallFrameForFrame(frame, host);
    SC_LOG(@"shrink frame %@ -> %@",
           NSStringFromCGRect(frame), NSStringFromCGRect(small));
    return small;
}

static CGRect hook_defaultContainerFrame(id self, SEL _cmd, CGSize referenceSize, CGRect hostBounds) {
    CGRect frame = orig_defaultContainerFrame(self, _cmd, referenceSize, hostBounds);
    return sc_maybeShrink(self, frame);
}

static CGRect hook_rememberedFrame(id self, SEL _cmd, id target, BOOL hostLandscape,
                                   BOOL contentLandscape, CGSize referenceSize, CGRect fallback) {
    CGRect frame = orig_rememberedFrame(self, _cmd, target, hostLandscape,
                                        contentLandscape, referenceSize, fallback);
    return sc_maybeShrink(self, frame);
}

static void sc_dockSessionIfPossible(SCFloatingSceneManager *manager) {
    id session = [manager activeSession];
    if (!session) {
        SC_LOG(@"activeSession == nil, skip dock");
        return;
    }
    NSInteger corner = sc_defaultDockCorner();
    BOOL docked = [manager sc_dockSession:session fromCorner:corner];
    if (!docked) {
        docked = [manager sc_dockSessionForSingleActiveWindow:session];
    }
    SC_LOG(@"dock corner=%ld ok=%d", (long)corner, docked);
}

static BOOL hook_openFrontmostAsSplit(id self, SEL _cmd, CGRect rect) {
    gInToolCall = YES;
    gShrunk = NO;
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
    gInToolCall = NO;
    if (!result) return result;

    @autoreleasepool {
#if SC_DOCK_MODE
        sc_dockSessionIfPossible((SCFloatingSceneManager *)self);
#endif
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
                    @selector(sc_defaultContainerFrameForReferenceSize:hostBounds:),
                    (IMP)hook_defaultContainerFrame,
                    (IMP *)&orig_defaultContainerFrame);

    MSHookMessageEx(cls,
                    @selector(sc_rememberedFrameForTargetIdentifier:hostLandscape:contentLandscape:referenceSize:fallback:),
                    (IMP)hook_rememberedFrame,
                    (IMP *)&orig_rememberedFrame);

    SC_LOG(@"hooked (mode=%d)", SC_DOCK_MODE);
}

%ctor {
    @autoreleasepool {
        installHook(0);
    }
}
