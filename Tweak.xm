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
    // 横屏下保持右侧那个视觉间距（8 + 缩掉的一半宽度），左侧照抄同一值。
    // 顶部只取该间距的 1/4（v0.2.3 按反馈缩短），不再叠整段状态栏高度。
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

    // 转发后仍未落成侧贴时，直接按 session 补一次 dock（走已 hook 的 sc_dockSession:fromCorner:）
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
    if (!session) {
        SC_LOG(@"landscape dock tap: no session for container");
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
        installHook(0);
    }
}
