# ScreenCoreDock v0.2.4

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.2.4`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

顶部位置已修好，本版只处理横屏点四角仍不进侧贴。

### 已验证的链路（反汇编确认）

四角落的 tap 手势是 `sc_addResizeGestureToRegion:corner:`（0x34564）装的：

```
0x3458c  setTag:          ; region view 的 tag = corner (1..4)
0x345a0  ldr x3,[0xab080]  ; sc_handleResizeGesture:
0x345a8  initWithTarget:action:   ; target = container
0x345b0  setMaximumNumberOfTouches:1
0x345c0  addGestureRecognizer:
0x345d4  ldr x3,[0xab088]  ; sc_handleDockTap:
0x345dc  initWithTarget:action:
0x345e8  setNumberOfTapsRequired:1
0x345f4  requireGestureRecognizerToFail:   ; tap 需要 pan 失败
0x34600  addGestureRecognizer:
```

即：点角落 -> `[container sc_handleDockTap:]`，target 就是容器本身，选择器也对得上 hook。

而转发后的 delegate 方法 `sc_floatingContainerView:didRequestDockFromCorner:`（0x4931c）内部是：

```
isMainThread -> sc_sessionForContainerView: -> sc_isLiveSession: -> sc_dockSession:fromCorner: -> sc_activateSession:
```

任何一步不满足就静默什么都不做。

### 本版改法

v0.2.3 在转发失败后会取 `sc_sessionForContainerView:` 再 dock。本版再补一层：如果这个容器查不到 session，就改用 `activeSession`：

```objc
id session = [delegate sc_sessionForContainerView:self];
if (!session) session = [delegate activeSession];
```

然后直接 `sc_dockSession:fromCorner:`（横屏会被顶成竖屏重入 + DockManager 兜底）。

同时把失败点都打出来：

```
landscape dock tap enter, superview={{0, 0}, {852, 393}}
landscape dock tap corner=N delegate=SCFloatingSceneManager
landscape dock tap ok via forward
landscape dock tap: container has no session, fall back to activeSession=SCFloatingSceneSession
landscape dock tap direct dock corner=N ok=1
landscape dock tap: no session at all
```

### 如果还是不行

看日志分两种情况：

1. **一行 `landscape dock tap` 都没有** —— 点击没进到 `sc_handleDockTap:`。那就是横屏下四角 region 没被布局/命中的问题（不是 dock 层），需要改从 `sc_layoutExternalInteractionRegions` 下手；
2. **有 `enter` 但 `ok=0` 或 `no session at all`** —— dock 层被拒，按日志里的 session 类型继续拆。

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 放开 `sc_dockSession:fromCorner:` 横屏方向守卫；
- v0.1.9 转入横屏不强制收回侧贴；
- v0.2.0 横屏卡片 0.5 缩放 + 紧凑重排（`LandscapeDockScale`）；
- v0.2.1 横屏左右间距对齐；
- v0.2.2 修安全模式（不再遍历全类表）；
- v0.2.3 顶部间距缩到 1/4。

## 真机验证

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```
