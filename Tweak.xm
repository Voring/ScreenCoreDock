//
//  Tweak.xm
//  ScreenCoreDock
//
//  目标：把 ScreenCore 2.0.5 的系统工具「全屏转ScreenCore分屏」
//  (system-tool:fullscreen-to-screencore-split) 的产物，改造成「侧贴小卡片浮窗」。
//
//  交互规则（本版 v0.1.4）：
//    - 松手位置贴近左/右边缘  -> 清除自由位置，回到插件原本的侧贴槽位吸附逻辑；
//    - 松手位置偏离两侧边缘  -> 停在当前位置，任意摆放，不再回槽位。
//
//  侧贴为什么天然不能自由移动：
//    拖拽结束 -> -sc_moveDraggingRecord:toSide:center:
//             -> -sc_updateNormalizedYForOrder:  把落点 Y 归一化成 order 序号
//             -> -sc_layoutSide:animated:completion:
//                -> -sc_targetFramesForSide: 按 (side, order) 重新算所有槽位
//                -> -sc_applyFrame:toRecord: 逐个应用
//    所以卡片坐标 = f(side, order)，松手必回槽位。
//
//  本版补丁点（v0.1.4）：
//    1) -sc_moveDraggingRecord:toSide:center:
//         用传入的 center（hostRootView 坐标系）判断是否贴边；
//         贴边 -> 清掉关联的自由中心；偏离 -> 记下落点中心。
//    2) -sc_targetFramesForSide:
//         槽位表里「有自由中心」的 record，把槽位平移到该中心（尺寸沿用槽位尺寸）。
//    3) -sc_applyFrame:toRecord:
//         落帧前再兜底一次：只平移，不改尺寸。
//     为什么要锁尺寸：sc_applyFrame: 内部会调 sc_dockTransformForRecord:targetFrame:，
//     它按「目标帧尺寸 / normalFrame 尺寸」算缩放。尺寸一旦被我们改大，卡片就会被放大数倍。
//
//  逆向依据（ScreenCore.dylib 2.0.5 arm64 切片，未滑动虚拟地址）：
//    _SCFullscreenToSplitToolPerform                    0x113a4
//      -> -sc_openFrontmostApplicationAsSplitFromSourceRect:   0x48eb8
//    frame: -sc_rememberedFrameForTargetIdentifier:... 0x43f1c / -sc_defaultContainerFrame... 0x43c1c
//    dock : -sc_dockSession:fromCorner: 0x463ac
//    布局: -sc_targetFramesForSide: 0x3a384 / -sc_layoutSide:animated:completion: 0x3b1fc
//          -sc_applyFrame:toRecord: 0x3ac70 / -sc_dockTransformForRecord:targetFrame: 0x3ab14
//          -sc_moveDraggingRecord:toSide:center: 0x3e5e4
//          -sc_dockedFloatingItemView:didMoveToCenter:state:velocity: 0x3f200
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <substrate.h>

#ifndef SC_DOCK_MODE
#define SC_DOCK_MODE 2
#endif

// 距离左/右边缘多少 pt 以内视为「贴边」，走原槽位吸附
#ifndef SC_EDGE_SNAP_INSET
#define SC_EDGE_SNAP_INSET 90.0
#endif

#define SC_DOMAIN CFSTR("com.susudear.screencore")
#define SC_LOG(fmt, ...) NSLog(@"[ScreenCoreDock] " fmt, ##__VA_ARGS__)

@interface SCFloatingSceneManager : NSObject
- (BOOL)sc_openFrontmostApplicationAsSplitFromSourceRect:(CGRect)rect;
- (id)activeSession;
- (BOOL)sc_dockSession:(id)session fromCorner:(NSInteger)corner;
- (BOOL)sc_dockSessionForSingleActiveWindow:(id)session;
@end

@interface SCFloatingDockRecord : NSObject
- (id)itemView;
- (id)session;
- (NSInteger)side;
@end

@interface SCFloatingDockManager : NSObject
- (UIView *)hostRootView;
- (NSDictionary *)sc_targetFramesForSide:(NSInteger)side;
- (void)sc_moveDraggingRecord:(id)record toSide:(NSInteger)side center:(CGPoint)center;
- (void)sc_applyFrame:(CGRect)frame toRecord:(id)record;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);

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
static void (*orig_applyFrame)(id, SEL, CGRect, id);

// 只记「用户希望的卡片中心点」。尺寸永远沿用插件给的槽位尺寸，
// 否则 sc_dockTransformForRecord:targetFrame: 会按尺寸比算缩放，把卡片放大。
static char kFreeCenterKey;   // record -> NSValue(CGPoint)，hostRootView 坐标系

static CGRect sc_hostBounds(id manager) {
    CGRect host = CGRectNull;
    @try {
        UIView *root = [(SCFloatingDockManager *)manager hostRootView];
        if (root) host = root.bounds;
    } @catch (__unused NSException *e) {}
    if (CGRectIsEmpty(host) || host.size.width < 1) host = [UIScreen mainScreen].bounds;
    return host;
}

static BOOL sc_isNearEdge(CGRect host, CGPoint center) {
    CGFloat inset = SC_EDGE_SNAP_INSET;
    return center.x <= CGRectGetMinX(host) + inset ||
           center.x >= CGRectGetMaxX(host) - inset;
}

/// 把中心点夹到 host 内（保证整张卡片不越界）
static CGPoint sc_clampCenter(CGPoint center, CGSize size, CGRect host) {
    CGFloat halfW = size.width / 2.0;
    CGFloat halfH = size.height / 2.0;
    CGFloat minX = CGRectGetMinX(host) + halfW;
    CGFloat maxX = CGRectGetMaxX(host) - halfW;
    CGFloat minY = CGRectGetMinY(host) + halfH;
    CGFloat maxY = CGRectGetMaxY(host) - halfH;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    center.x = MAX(minX, MIN(maxX, center.x));
    center.y = MAX(minY, MIN(maxY, center.y));
    return center;
}

static CGRect sc_rectCenteredAt(CGPoint center, CGSize size) {
    return CGRectMake(center.x - size.width / 2.0,
                      center.y - size.height / 2.0,
                      size.width, size.height);
}

static NSDictionary *hook_targetFramesForSide(id self, SEL _cmd, NSInteger side) {
    NSDictionary *frames = orig_targetFramesForSide(self, _cmd, side);
    if (!frames.count) return frames;

    CGRect host = sc_hostBounds(self);
    NSMutableDictionary *patched = nil;
    for (id key in [frames allKeys]) {
        id record = nil;
        if ([key isKindOfClass:[NSValue class]]) {
            @try { record = [(NSValue *)key nonretainedObjectValue]; } @catch (__unused NSException *e) {}
        }
        if (!record) record = key;

        NSValue *custom = objc_getAssociatedObject(record, &kFreeCenterKey);
        if (!custom) continue;

        // 关键：尺寸用插件算好的槽位尺寸，只换位置
        CGRect slot = [frames[key] CGRectValue];
        CGPoint center = sc_clampCenter([custom CGPointValue], slot.size, host);
        CGRect moved = sc_rectCenteredAt(center, slot.size);

        if (!patched) patched = [frames mutableCopy];
        patched[key] = [NSValue valueWithCGRect:moved];
        SC_LOG(@"free center applied for record %p -> %@ (slot %@)",
               record, NSStringFromCGRect(moved), NSStringFromCGRect(slot));
    }
    return patched ?: frames;
}

static void hook_moveDraggingRecord(id self, SEL _cmd, id record, NSInteger side, CGPoint center) {
    CGRect host = sc_hostBounds(self);
    BOOL nearEdge = sc_isNearEdge(host, center);

    if (nearEdge) {
        // 贴边：清掉自由位置，让 orig 走原槽位吸附
        objc_setAssociatedObject(record, &kFreeCenterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SC_LOG(@"drop near edge (side=%ld center=%@) -> snap to slot",
               (long)side, NSStringFromCGPoint(center));
    } else {
        objc_setAssociatedObject(record, &kFreeCenterKey,
                                 [NSValue valueWithCGPoint:center],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SC_LOG(@"drop free (side=%ld center=%@ host=%@)",
               (long)side, NSStringFromCGPoint(center), NSStringFromCGRect(host));
    }

    orig_moveDraggingRecord(self, _cmd, record, side, center);
}

/// 落帧兜底：只平移，不改尺寸
static void hook_applyFrame(id self, SEL _cmd, CGRect frame, id record) {
    NSValue *custom = objc_getAssociatedObject(record, &kFreeCenterKey);
    if (custom) {
        CGRect host = sc_hostBounds(self);
        CGPoint center = sc_clampCenter([custom CGPointValue], frame.size, host);
        CGRect moved = sc_rectCenteredAt(center, frame.size);
        SC_LOG(@"applyFrame moved %@ -> %@", NSStringFromCGRect(frame), NSStringFromCGRect(moved));
        orig_applyFrame(self, _cmd, moved, record);
        return;
    }
    orig_applyFrame(self, _cmd, frame, record);
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
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
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

#if SC_DOCK_MODE == 2
    MSHookMessageEx(dockCls,
                    @selector(sc_targetFramesForSide:),
                    (IMP)hook_targetFramesForSide,
                    (IMP *)&orig_targetFramesForSide);
    MSHookMessageEx(dockCls,
                    @selector(sc_moveDraggingRecord:toSide:center:),
                    (IMP)hook_moveDraggingRecord,
                    (IMP *)&orig_moveDraggingRecord);
    MSHookMessageEx(dockCls,
                    @selector(sc_applyFrame:toRecord:),
                    (IMP)hook_applyFrame,
                    (IMP *)&orig_applyFrame);
    SC_LOG(@"hooked (mode=2, dockClass=%s, edgeInset=%.0f)",
           class_getName(dockCls), SC_EDGE_SNAP_INSET);
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
