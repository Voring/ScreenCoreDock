//
//  Tweak.xm
//  ScreenCoreDock  v0.1.7
//
//  三种模式，靠偏好开关切换：
//
//    FreeFloatMode = 0（默认）  侧贴浮窗（v0.1.0 行为）：打开后 dock 到侧边，
//                              卡片沿侧边自上而下堆叠，位置由插件布局决定。
//
//    FreeFloatMode = 1          取消停靠 -> 普通浮窗（displayState 3）：
//                              走插件自己的 -sc_restoreRecordToNormalFrame:animated:completion:。
//
//    FreeFloatMode = 2          dock 内任意位置：
//                              仍是侧贴状态（displayState 1），但每张卡片可以停在
//                              拖拽落点，不再被"自上而下堆叠"的布局拉回去。
//
//  —— 为什么模式 2 要动三处 ——
//
//  反汇编结论（arm64 切片，未滑动地址）：
//
//  1) -sc_updateNormalizedYForOrder:（0x3e52c）
//       遍历数组，对每条 record 调 setNormalizedY:(i+1)/(count+1)。
//       它完全忽略落点 Y，normalizedY 只是序号百分比。
//       normalizedY 的用途只有排序（-sc_sortedRecordsForSide:）。
//
//  2) -sc_targetFramesForSide:（0x3a384）
//       取 sortedRecordsForSide，逐条算尺寸后累加 Y：
//         0x3aa84  y = y + (gap + height)        // gap = count>1 ? 18 : 0
//       纵向没有任何"槽位"参数可调，就是自上而下堆叠。
//       所以想任意放置，只能覆盖它返回的帧表。
//
//  3) -sc_dockedFloatingItemView:didMoveToCenter:state:velocity:（0x3f200）
//       拖拽收尾层。内部 0x3f664 又调 -sc_moveDraggingRecord:toSide:center:，
//       随后用 hostRootView bounds 内联算槽位 x、对 y 夹紧，直接
//       setCenter: 到 itemView(0x3f74c) 和 containerView(0x3f77c)，绕过 applyFrame。
//       这一层不摁住，就会出现：只能沿中轴线移动 / 左右闪烁 / 回不到两侧。
//
//  模式 2 的实现：
//    A. hook  -sc_moveDraggingRecord:toSide:center:
//         记下落点中心（hostRootView 坐标系）+ 记下当时的 side，保持 side 不变，
//         避免 0x3e790 用 center.x 与帧 x 比较导致 side 反复翻转（闪烁来源）。
//    B. hook  -sc_targetFramesForSide:
//         对"有自由中心"的 record，把槽位**平移**到该中心，尺寸沿用槽位尺寸
//         （尺寸必须沿用：-sc_applyFrame:toRecord: 内部会按 目标帧尺寸/normalFrame 尺寸
//          算缩放，尺寸被改大就会把卡片放大数倍）。
//    C. hook  -sc_dockedFloatingItemView:didMoveToCenter:state:velocity:
//         命中自由记录时直接返回，不调 orig —— 让 A/B 决定位置。
//
//  已验证选择器：
//    -sc_openFrontmostApplicationAsSplitFromSourceRect:      0x48eb8
//    -activeSession          0x65260(stub)   -dockManager    0x66880
//    -records                0x69120          -itemView       0x39e80
//    -session                0x6c920(stub)    -side          0x70320
//    -sc_recordsForSide:     0x3a170
//    -sc_targetFramesForSide: 0x3a384
//    -sc_moveDraggingRecord:toSide:center: 0x3e5e4(stub 0x6af20)
//    -sc_dockedFloatingItemView:didMoveToCenter:state:velocity: 0x3f200
//    -sc_restoreRecordToNormalFrame:animated:completion: 0x3c7e0
//    -displayState / -setDisplayState: 0x66820 / 0x6d7a0(stub)
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
- (UIView *)hostRootView;
- (NSArray *)records;
- (NSArray *)sc_recordsForSide:(NSInteger)side;
- (NSDictionary *)sc_targetFramesForSide:(NSInteger)side;
- (void)sc_moveDraggingRecord:(id)record toSide:(NSInteger)side center:(CGPoint)center;
- (void)sc_applyFrame:(CGRect)frame toRecord:(id)record;
- (void)sc_dockedFloatingItemView:(UIView *)itemView
                   didMoveToCenter:(CGPoint)center
                            state:(NSInteger)state
                         velocity:(CGPoint)velocity;
- (void)sc_restoreRecordToNormalFrame:(id)record
                            animated:(BOOL)animated
                          completion:(void (^)(void))completion;
@end

@interface SCFloatingDockRecord : NSObject
- (UIView *)itemView;
- (id)session;
- (NSInteger)side;
@end

@interface SCFloatingContainer : NSObject
- (NSInteger)displayState;
- (void)setDisplayState:(NSInteger)state;
@end

static BOOL (*orig_openFrontmostAsSplit)(id, SEL, CGRect);

static NSDictionary *(*orig_targetFramesForSide)(id, SEL, NSInteger);
static void (*orig_moveDraggingRecord)(id, SEL, id, NSInteger, CGPoint);
static void (*orig_didMoveToCenter)(id, SEL, UIView *, CGPoint, NSInteger, CGPoint);

// record -> NSValue(CGPoint)：用户希望的卡片中心（hostRootView 坐标系）
static char kFreeCenterKey;

#pragma mark - 偏好

static NSInteger sc_mode(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(SC_PREF_KEY, SC_TWEAK_DOMAIN);
    NSInteger mode = 0;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            mode = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
        } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            mode = [(__bridge NSNumber *)v integerValue];
        } else if (CFGetTypeID(v) == CFStringGetTypeID()) {
            mode = [(__bridge NSString *)v integerValue];
        }
        CFRelease(v);
    }
    if (mode < 0 || mode > 2) mode = 0;
    return mode;
}

static NSInteger sc_defaultDockCorner(void) {
    NSNumber *side = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"), SC_DOMAIN);
    if (![side isKindOfClass:[NSNumber class]]) return 1;
    return ([side integerValue] == 1) ? 2 : 1;
}

#pragma mark - 工具

static CGRect sc_hostBounds(id dock) {
    CGRect host = CGRectNull;
    @try {
        UIView *root = [(SCFloatingDockManager *)dock hostRootView];
        if (root) host = root.bounds;
    } @catch (__unused NSException *e) {}
    if (CGRectIsEmpty(host) || host.size.width < 1) host = [UIScreen mainScreen].bounds;
    return host;
}

static CGPoint sc_clampCenter(CGPoint c, CGSize size, CGRect host) {
    CGFloat hw = size.width / 2.0, hh = size.height / 2.0;
    CGFloat minX = CGRectGetMinX(host) + hw, maxX = CGRectGetMaxX(host) - hw;
    CGFloat minY = CGRectGetMinY(host) + hh, maxY = CGRectGetMaxY(host) - hh;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    c.x = MAX(minX, MIN(maxX, c.x));
    c.y = MAX(minY, MIN(maxY, c.y));
    return c;
}

static CGRect sc_rectCenteredAt(CGPoint c, CGSize size) {
    return CGRectMake(c.x - size.width / 2.0, c.y - size.height / 2.0, size.width, size.height);
}

/// 从 itemView 反查 record
static id sc_recordForItemView(id dock, UIView *itemView) {
    if (!dock || !itemView) return nil;
    NSArray *all = nil;
    @try { all = [(SCFloatingDockManager *)dock records]; } @catch (__unused NSException *e) {}
    for (id record in all) {
        UIView *view = nil;
        @try { view = [(SCFloatingDockRecord *)record itemView]; } @catch (__unused NSException *e) {}
        if (view == itemView) return record;
    }
    return nil;
}

#pragma mark - 模式 0：dock 到侧边（v0.1.0 行为）

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

    NSInteger restored = 0;
    if ([dock respondsToSelector:@selector(sc_recordsForSide:)] &&
        [dock respondsToSelector:@selector(sc_restoreRecordToNormalFrame:animated:completion:)]) {
        for (NSInteger side = 1; side <= 2; side++) {
            NSArray *recs = nil;
            @try { recs = [(SCFloatingDockManager *)dock sc_recordsForSide:side]; }
            @catch (NSException *e) { SC_LOG(@"free path: recordsForSide:%ld threw %@", (long)side, e.reason); }

            for (id record in recs) {
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

#pragma mark - 模式 2：dock 内任意位置

static void hook_moveDraggingRecord(id self, SEL _cmd, id record, NSInteger side, CGPoint center) {
    CGRect host = sc_hostBounds(self);

    // 记录落点；同时把 side 钉住，避免 0x3e790 按 center.x 反复翻转 side（闪烁源）
    NSInteger pinned = side;
    NSValue *oldSide = objc_getAssociatedObject(record, @"kPinnedSide");
    if (oldSide) pinned = [oldSide integerValue];

    objc_setAssociatedObject(record, &kFreeCenterKey,
                             [NSValue valueWithCGPoint:center],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(record, @"kPinnedSide",
                             @(pinned),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SC_LOG(@"drag drop record=%p side=%ld pinned=%ld center=%@ host=%@",
           record, (long)side, (long)pinned, NSStringFromCGPoint(center), NSStringFromCGRect(host));

    orig_moveDraggingRecord(self, _cmd, record, pinned, center);
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

        NSValue *pinnedSide = objc_getAssociatedObject(record, @"kPinnedSide");
        if (pinnedSide && [pinnedSide integerValue] != side) continue;  // 只改它自己那一侧

        CGRect slot = [frames[key] CGRectValue];          // 尺寸沿用槽位尺寸
        CGPoint c = sc_clampCenter([custom CGPointValue], slot.size, host);
        CGRect moved = sc_rectCenteredAt(c, slot.size);

        if (!patched) patched = [frames mutableCopy];
        patched[key] = [NSValue valueWithCGRect:moved];
        SC_LOG(@"frames side=%ld record=%p %@ -> %@", (long)side, record,
               NSStringFromCGRect(slot), NSStringFromCGRect(moved));
    }
    return patched ?: frames;
}

/// 收尾层直接吞掉：它内部会再算槽位并对 itemView/containerView setCenter
static void hook_didMoveToCenter(id self, SEL _cmd, UIView *itemView, CGPoint center,
                                 NSInteger state, CGPoint velocity) {
    id record = sc_recordForItemView(self, itemView);
    NSValue *custom = record ? objc_getAssociatedObject(record, &kFreeCenterKey) : nil;
    if (record && custom) {
        CGRect host = sc_hostBounds(self);
        CGPoint c = sc_clampCenter([custom CGPointValue], itemView.bounds.size, host);
        itemView.center = c;
        SC_LOG(@"didMove swallowed record=%p -> center=%@ (orig would use %@)",
               record, NSStringFromCGPoint(c), NSStringFromCGPoint(center));
        return;
    }
    orig_didMoveToCenter(self, _cmd, itemView, center, state, velocity);
}

#pragma mark - 入口

static BOOL hook_openFrontmostAsSplit(id self, SEL _cmd, CGRect rect) {
    BOOL result = orig_openFrontmostAsSplit(self, _cmd, rect);
    if (!result) {
        SC_LOG(@"open returned NO, nothing to do");
        return result;
    }

    SCFloatingSceneManager *manager = (SCFloatingSceneManager *)self;
    NSInteger mode = sc_mode();
    SC_LOG(@"open ok, mode=%ld", (long)mode);

    switch (mode) {
        case 0:
            @autoreleasepool { sc_dockSession(manager); }
            break;
        case 1:
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    id session = [manager activeSession];
                    if (!session) { SC_LOG(@"free path: activeSession == nil"); return; }
                    sc_tryRestoreToNormalFloating(manager, session);
                }
            });
            break;
        case 2:
        default:
            // 仍需 dock 到侧边，只是后续位置由 A/B/C 接管
            @autoreleasepool { sc_dockSession(manager); }
            break;
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

    // dock 侧三枚：始终安装，非模式 2 时靠 assoc 为空自动放行
    Class dockCls = objc_getClass("SCFloatingDockManager");
    if (!dockCls) {
        SC_LOG(@"SCFloatingDockManager not found, dock hooks skipped");
    } else {
        MSHookMessageEx(dockCls,
                        @selector(sc_targetFramesForSide:),
                        (IMP)hook_targetFramesForSide,
                        (IMP *)&orig_targetFramesForSide);
        MSHookMessageEx(dockCls,
                        @selector(sc_moveDraggingRecord:toSide:center:),
                        (IMP)hook_moveDraggingRecord,
                        (IMP *)&orig_moveDraggingRecord);
        MSHookMessageEx(dockCls,
                        @selector(sc_dockedFloatingItemView:didMoveToCenter:state:velocity:),
                        (IMP)hook_didMoveToCenter,
                        (IMP *)&orig_didMoveToCenter);
    }

    SC_LOG(@"hooked (mode=%ld, dockClass=%s)", (long)sc_mode(), dockCls ? class_getName(dockCls) : "nil");
}

%ctor {
    @autoreleasepool {
        installHook(0);
    }
}
