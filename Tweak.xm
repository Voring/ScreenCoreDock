//
//  Tweak.xm
//  ScreenCoreDock
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」
//  (system-tool:fullscreen-to-screencore-split) 的产物，改造成「侧贴小卡片浮窗，且可自由摆放」。
//
//  编译期模式：
//    SC_DOCK_MODE 0 = 小尺寸普通浮窗（可拖可缩放，但不是卡片形态）
//    SC_DOCK_MODE 1 = 侧贴卡片，位置由 dockManager 槽位决定（不可自由摆放）
//    SC_DOCK_MODE 2 = 侧贴卡片 + 自由摆放（默认，你要的那种）
//
//  侧贴为什么天然不能自由移动：
//    拖拽结束 -> -sc_moveDraggingRecord:toSide:center:
//             -> -sc_updateNormalizedYForOrder:  把落点 Y 归一化成 order 序号
//             -> -sc_layoutSide:animated:completion:
//                -> -sc_targetFramesForSide: 按 (side, order) 重新算所有槽位
//                -> -sc_applyFrame:toRecord: 逐个应用
//    所以卡片坐标 = f(side, order)，松手必回槽位。
//  做法：hook -sc_targetFramesForSide:，把「有自定义位置」的 record 的槽位替换成用户拖到的矩形；
//       在 -sc_moveDraggingRecord:toSide:center: 落地时把当时 itemView 的 frame 记下来。
//
//  逆向依据（ScreenCore.dylib 2.0.5 arm64 切片，未滑动虚拟地址）：
//    _SCFullscreenToSplitToolPerform                    0x113a4
//      -> -sc_openFrontmostApplicationAsSplitFromSourceRect:   0x48eb8
//         -> -sc_openSplitForBundleIdentifier:presentationSourceRect:  0x46cf4
//            -> ... 0x47f60（建窗口）
//    frame: -sc_rememberedFrameForTargetIdentifier:... 0x43f1c / -sc_defaultContainerFrameForReferenceSize:hostBounds: 0x43c1c
//    dock : -sc_dockSession:fromCorner: 0x463ac / -sc_dockSessionForSingleActiveWindow: 0x462e4
//    布局: -sc_targetFramesForSide: 0x3a384 / -sc_layoutSide:animated:completion: 0x3b1fc
//          -sc_moveDraggingRecord:toSide:center: （stub 0x6af20）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <substrate.h>

#ifndef SC_DOCK_MODE
#define SC_DOCK_MODE 2
#endif

// Theos/roothide 默认开 -Werror：没被当前模式用到的静态函数会直接编译失败，统一标注 unused
#define SC_UNUSED __attribute__((unused))

// 仅 SC_DOCK_MODE == 0 时使用
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

@interface SCFloatingDockRecord : NSObject
- (id)itemView;
- (id)session;
- (NSInteger)side;
@end

@interface SCFloatingDockManager : NSObject
- (NSDictionary *)sc_targetFramesForSide:(NSInteger)side;
- (void)sc_moveDraggingRecord:(id)record toSide:(NSInteger)side center:(CGPoint)center;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);

#pragma mark - 小尺寸自由浮窗（mode 0）

#if SC_DOCK_MODE == 0

static CGRect (*orig_defaultContainerFrame)(id, SEL, CGSize, CGRect);
static CGRect (*orig_rememberedFrame)(id, SEL, id, BOOL, BOOL, CGSize, CGRect);

static BOOL gInToolCall = NO;
static BOOL gShrunk = NO;

static CGRect sc_smallFrameForFrame(CGRect original, CGRect host) {
    if (host.size.width < 1 || host.size.height < 1) host = [UIScreen mainScreen].bounds;
    CGFloat ratio = (original.size.width > 1) ? (original.size.height / original.size.width) : 1.0;
    if (ratio < 0.5 || ratio > 2.5) ratio = host.size.height / host.size.width;

    CGFloat w = host.size.width * SC_FLOAT_WIDTH_RATIO;
    CGFloat h = w * ratio;
    CGFloat maxH = host.size.height * SC_FLOAT_MAX_HEIGHT_RATIO;
    if (h > maxH) { h = maxH; w = h / ratio; }
    if (w < 120.0) { w = 120.0; h = w * ratio; }

    return CGRectMake(CGRectGetMidX(host) - w / 2.0, CGRectGetMidY(host) - h / 2.0, w, h);
}

static CGRect sc_maybeShrink(id manager, CGRect frame) {
    if (!gInToolCall || gShrunk) return frame;
    gShrunk = YES;
    CGRect host = CGRectNull;
    if ([manager respondsToSelector:@selector(sc_hostBoundsForActiveOrientation)]) {
        host = [manager sc_hostBoundsForActiveOrientation];
    }
    if (CGRectIsEmpty(host) || host.size.width < 1) host = [UIScreen mainScreen].bounds;

    CGRect small = sc_smallFrameForFrame(frame, host);
    SC_LOG(@"shrink frame %@ -> %@", NSStringFromCGRect(frame), NSStringFromCGRect(small));
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

#endif // SC_DOCK_MODE == 0

#pragma mark - 侧贴（mode 1 / 2）

#if SC_DOCK_MODE != 0

static NSInteger sc_defaultDockCorner(void) {
    NSNumber *side = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"), SC_DOMAIN);
    if (![side isKindOfClass:[NSNumber class]]) return 1;
    return ([side integerValue] == 1) ? 2 : 1;
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

#endif // SC_DOCK_MODE != 0

#pragma mark - 自由摆放（mode 2）

#if SC_DOCK_MODE == 2

static NSDictionary *(*orig_targetFramesForSide)(id, SEL, NSInteger);
static void (*orig_moveDraggingRecord)(id, SEL, id, NSInteger, CGPoint);

static char kFreeFrameKey;   // record -> NSValue(CGRect)：用户摆的绝对位置

/// 把槽位表里「用户摆过位置」的 record 换成它的自定义矩形
static NSDictionary *hook_targetFramesForSide(id self, SEL _cmd, NSInteger side) {
    NSDictionary *frames = orig_targetFramesForSide(self, _cmd, side);
    if (!frames.count) return frames;

    NSMutableDictionary *patched = nil;
    for (id key in [frames allKeys]) {
        id record = nil;
        if ([key isKindOfClass:[NSValue class]]) {
            @try { record = [(NSValue *)key nonretainedObjectValue]; } @catch (__unused NSException *e) {}
        }
        if (!record) record = key;

        NSValue *custom = objc_getAssociatedObject(record, &kFreeFrameKey);
        if (!custom) continue;

        if (!patched) patched = [frames mutableCopy];
        patched[key] = custom;
        SC_LOG(@"free frame applied for record %p -> %@", record, NSStringFromCGRect([custom CGRectValue]));
    }
    return patched ?: frames;
}

/// 落地时记下 itemView 当时的绝对 frame（orig 会把它归一化成 order，所以要提前取）
static void hook_moveDraggingRecord(id self, SEL _cmd, id record, NSInteger side, CGPoint center) {
    CGRect captured = CGRectNull;
    @try {
        id view = [(SCFloatingDockRecord *)record itemView];
        if (view) captured = [view frame];
    } @catch (__unused NSException *e) {}

    orig_moveDraggingRecord(self, _cmd, record, side, center);

    if (record && !CGRectIsNull(captured) && captured.size.width > 1) {
        objc_setAssociatedObject(record, &kFreeFrameKey,
                                 [NSValue valueWithCGRect:captured],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SC_LOG(@"remember free frame %@ for record %p", NSStringFromCGRect(captured), record);
    }
}

static Class sc_classRespondingTo(SEL sel) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return Nil;
    count = objc_getClassList(classes, count);
    Class found = Nil;
    for (int i = 0; i < count; i++) {
        if (classes[i] && class_respondsToSelector(classes[i], sel)) { found = classes[i]; break; }
    }
    free(classes);
    return found;
}

#endif // SC_DOCK_MODE == 2

#pragma mark - 主入口 hook

static BOOL hook_openFrontmostAsSplit(id self, SEL _cmd, CGRect rect) {
#if SC_DOCK_MODE == 0
    gInToolCall = YES;
    gShrunk = NO;
#endif
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
#if SC_DOCK_MODE == 0
    gInToolCall = NO;
#endif
    if (!result) return result;

    @autoreleasepool {
#if SC_DOCK_MODE != 0
        sc_dockSessionIfPossible((SCFloatingSceneManager *)self);
#endif
    }
    return result;
}

#pragma mark - 安装

static void installHook(int attempt) {
    Class cls = objc_getClass("SCFloatingSceneManager");

#if SC_DOCK_MODE == 2
    Class dockCls = sc_classRespondingTo(@selector(sc_targetFramesForSide:));
    if (!cls || !dockCls) {
        if (attempt >= 50) {
            SC_LOG(@"classes not found (scene=%p dock=%p), hook aborted", cls, dockCls);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            installHook(attempt + 1);
        });
        return;
    }
#else
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
#endif

    MSHookMessageEx(cls,
                    @selector(sc_openFrontmostApplicationAsSplitFromSourceRect:),
                    (IMP)hook_openFrontmostAsSplit,
                    (IMP *)&orig_openFrontmostAsSplit);

#if SC_DOCK_MODE == 0
    MSHookMessageEx(cls,
                    @selector(sc_defaultContainerFrameForReferenceSize:hostBounds:),
                    (IMP)hook_defaultContainerFrame,
                    (IMP *)&orig_defaultContainerFrame);
    MSHookMessageEx(cls,
                    @selector(sc_rememberedFrameForTargetIdentifier:hostLandscape:contentLandscape:referenceSize:fallback:),
                    (IMP)hook_rememberedFrame,
                    (IMP *)&orig_rememberedFrame);
    SC_LOG(@"hooked (mode=0)");
#endif

#if SC_DOCK_MODE == 2
    MSHookMessageEx(dockCls,
                    @selector(sc_targetFramesForSide:),
                    (IMP)hook_targetFramesForSide,
                    (IMP *)&orig_targetFramesForSide);
    MSHookMessageEx(dockCls,
                    @selector(sc_moveDraggingRecord:toSide:center:),
                    (IMP)hook_moveDraggingRecord,
                    (IMP *)&orig_moveDraggingRecord);
    SC_LOG(@"hooked (mode=2, dockClass=%s)", class_getName(dockCls));
#endif

#if SC_DOCK_MODE == 1
    SC_LOG(@"hooked (mode=1)");
#endif
}

%ctor {
    @autoreleasepool {
        installHook(0);
    }
}
