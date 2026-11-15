# ScreenCoreDock v0.2.3

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.2.3`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

本版两件事：横屏点四角补 session 兜底；顶部间距缩到 1/4。

### 横屏点四角仍然无效（本版补兜底 + 日志）

v0.2.2 已确认 hook 挂上 `SCFloatingContainerView -sc_handleDockTap:`（日志有 `hooked sc_handleDockTap: on SCFloatingContainerView`），但横屏点角仍无反应，说明「转发给 delegate」这一步没有真的把窗口落成侧贴。

原方法末尾那一步是：

```
0x3878c  [self sc_notifyActivationRequested]
0x38794  delegate
0x387a8  [[gesture view] tag]      ; corner
0x387cc  [delegate sc_floatingContainerView:self didRequestDockFromCorner:corner]
```

本版在横屏分支里改成三段：

1. 先照原样转发 `sc_floatingContainerView:didRequestDockFromCorner:`；
2. 转发后回读 `isDocked`，如果没变成侧贴，则用 `sc_sessionForContainerView:` 取该容器对应的 session（`SCFloatingSceneManager` 确实有这个方法）；
3. 拿到 session 后直接 `sc_dockSession:fromCorner:`，也就是走已 hook 的那条路径（横屏会被顶成竖屏重入 + DockManager 兜底）。

同时补了三行诊断日志，横屏点角时依次会打出：

```
landscape dock tap enter, superview={{0, 0}, {852, 393}}
landscape dock tap corner=N delegate=SCFloatingSceneManager
landscape dock tap ok via forward        <- 或 direct dock corner=N ok=1
```

如果**一条都没打**，说明点击根本没进到 `sc_handleDockTap:`（那问题在四角落手势是否在横屏下被安装/命中，方向不同）。

### 横屏顶部间距过大（本版缩到 1/4）

v0.2.1 的顶部间距是 `margin + 状态栏高度`，`margin = 8 + 旧宽 × (1 - scale)` 在横向约 93pt，叠上状态栏约 47pt，实际顶部空出约 140pt，太远。

本版改为：

```objc
CGFloat topGap = (margin + sc_statusBarHeight()) * 0.25;   // 约 35pt
```

左右间距保持不变（仍是横屏右侧那个视觉间距，左侧同值）。

### 保留的既有改动

- v0.1.8 放开 `sc_dockSession:fromCorner:` 的横屏方向守卫；
- v0.1.9 转入横屏不再强制收回侧贴；
- v0.2.0 横屏卡片 0.5 缩放 + 紧凑重排（`LandscapeDockScale`）；
- v0.2.1 横屏点角转发 + 左右间距对齐；
- v0.2.2 不再遍历全类表，按类名 hook，修安全模式。

## 真机验证

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

1. 转横屏：应看到 `landscape frames side=1 ...` 与 `landscape frames side=2 ...`，顶部气泡明显上移（约 35pt）；
2. 横屏点浮窗四角：看是否打出 `landscape dock tap enter`。打出但 `ok=0`，把这几行发我；一条都没打，也请说明，那就是手势层问题而不是 dock 层问题。
