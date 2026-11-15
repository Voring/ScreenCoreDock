# ScreenCoreDock v0.3.5

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.5`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 上一个版为何又崩

v0.3.4 的 ips（`SpringBoard-2026-11-15-192652.ips`）崩溃帧：

```
NSStringFromClass
objc_class::demangledName(bool)      <- 拷到一个非法类对象就炸
_dispatch_continuation_pop          <- 我们 5 秒后的 dispatch_after 块
ScreenCoreDock.dylib + 0x6978
```

即：即使拖到 5 秒后再碰 `SBCoverSheetPresentationManager`，拿回来的东西不是合法对象，`NSStringFromClass` 一调用就崩。这个类在 SpringBoard 里不可随便探。

## 本版改法

彻底不碰 `SBCoverSheetPresentationManager`，改用窗口层判断：

```objc
static BOOL sc_windowClassNameContains(const char *needle) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        const char *n = object_getClassName(w);
        if (n && strstr(n, needle)) return YES;
    }
    return NO;
}

static BOOL sc_coverSheetPresented(void) {
    return sc_windowClassNameContains("CoverSheet")
        || sc_windowClassNameContains("NotificationCenter");
}
```

只用 `object_getClassName`：不构造 NSString、不查类、不碰单例，安全。

回收拦截点保持：undock / restoreAll / closeSession / closeAll 均在该状态下跳过，restoreRecord 只记日志。

## 启动 5 秒后的日志

```
windows at 5s: <SBWindow> <SBCoverSheetWindow> ...
coverSheet by window name = 0
```

这两行是本版的关键诊断：

- 若上面能看到类似 `SBCoverSheetWindow` / `SBNotificationCenterWindow` 的类名，说明判断依据可用；下拉通知中心后同样的判定就能命中；
- 若窗口列表里完全看不到相关类名，把这一行回传，我改为按窗口层级或视图类名匹配。

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 / v0.1.9 横屏可侧贴且不强制收回；
- v0.2.0~v0.2.3 横屏 1/4 缩放与左右/顶部间距；
- v0.3.0 移除四角监听与点角链路；
- v0.3.1 左区域改为关闭浮窗。
