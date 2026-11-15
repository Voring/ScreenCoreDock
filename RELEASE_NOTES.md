# ScreenCoreDock v0.3.2

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.2`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

下拉通知中心不再收回已侧贴的应用。控制中心不受影响（原本就不受影响）。

### 与横屏收回是否共通

不共通。全文件只有一处调用 `sc_restoreAllDockedSessionsAnimated:`：

```
0x42ee0  bl  sc_restoreAllDockedSessionsAnimated:   ; 只在 sc_activeHostOrientationDidChange:duration: 尾部
```

而通知中心走的是另一条：ScreenCore 的通知工具直接向 SpringBoard 要 CoverSheet：

```
0x104d8  CFSTR "SBCoverSheetPresentationManager"
0x104f8  sharedInstance
0x1052c  setCoverSheetPresented:animated:withCompletion:
```

所以不能省代码，得单独处理。

### 本版改法

1. 读 CoverSheet 状态：

```objc
Class cs = objc_getClass("SBCoverSheetPresentationManager");
id mgr = [cs sharedInstance];
BOOL shown = [mgr isCoverSheetPresented];
```

2. 在收回入口上判断：
   - `SCFloatingDockManager -sc_undockSession:animated:`（0x3ce94）：CoverSheet 展示时直接返回，不收；
   - `SCFloatingDockManager -sc_restoreAllDockedSessionsAnimated:`（0x3d13c）：同样跳过；
   - `SCFloatingSceneManager -sc_closeSession:animated:`（0x4b044）：本版只记录，不改行为。

### 日志

```
v0.3.2 loaded in SpringBoard
hooked sc_undockSession:animated: (skip while cover sheet shown)
v0.3.2 ... keepOnCoverSheet
notification center shown: skip undockSession:SCFloatingSceneSession
notification center shown: skip restoreAllDockedSessionsAnimated:
sc_closeSession:animated: called (coverSheet=1) session=SCFloatingSceneSession
```

如果下拉通知中心后卡片仍然没了，看日志里到底出现哪一行：

- 只有 `skip undock...` 却还是消失 -> 走的是 `sc_closeSession:animated:`，下一版直接拦它；
- 完全没有这类日志 -> 走的不是这两个入口，需要再从 `sc_prepareForExternalForegroundLaunchOfBundleIdentifier:` / `willDismissSession:` 查。

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 / v0.1.9 横屏可侧贴且不强制收回；
- v0.2.0~v0.2.3 横屏 1/4 缩放与左右/顶部间距；
- v0.3.0 移除四角监听与点角链路；
- v0.3.1 左区域改为关闭浮窗。
