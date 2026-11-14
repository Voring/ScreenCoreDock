# ScreenCoreDock v0.1.1

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.1`
- 架构：`iphoneos-arm64`（含 arm64 + arm64e 切片）
- 打包方案：`rootless` 与 `roothide` 两份 deb

## 本版改动

工具「全屏转ScreenCore分屏」的产物，由**居中大浮窗（分屏浮窗）**改为**小尺寸自由浮窗**：

- 宽度默认 = 屏幕宽 * `0.45`（iPhone 上约 170pt），高度按原窗口长宽比推算，最高不超过屏幕高 `0.70`；
- 居中弹出，**可自由拖动、可缩放、可继续操作**（普通浮窗状态，`displayState` 不变）；
- 不再侧贴，因此不再受「固定屏墓两侧 + 顶部自上而下排序」的布局约束。

### 为什么不能用「侧贴状态」做自由移动

侧贴（docked）的坐标不是绝对坐标，而是 `(side, 顺序号)` 的函数：`SCFloatingDockManager` 用 `sc_sortedRecordsForSide:` 排序、`sc_targetFramesForSide:` 算槽位、`sc_layoutDockedItemsAnimated:` 统一重排。
拖动只改变顺序或换边，松手必定回槽位，所以「自由摆放」在 dock 状态下无法实现（除非改写整个 dock 布局引擎）。

若要回到侧贴小卡片，编译时把 `SC_DOCK_MODE` 设为 `1` 即可（顺手保留），但那种形态仍然不能自由摆放。

### 实现方式

不修改 ScreenCore 原包，独立 tweak hook 三个方法：

| 方法 | 作用 |
|---|---|
| `-sc_openFrontmostApplicationAsSplitFromSourceRect:` | 工具入口；调用期间打上标记 `gInToolCall` |
| `-sc_defaultContainerFrameForReferenceSize:hostBounds:` | 无记忆帧时的 fallback 几何，命中标记则返回小窗口 rect |
| `-sc_rememberedFrameForTargetIdentifier:hostLandscape:contentLandscape:referenceSize:fallback:` | 有「记忆大小位置」时的几何，同样收缩 |

`gShrunk` 保证每次工具调用只收缩一次（两个入口都可能被走到）；标记在调用结束即清除，ARC / 侧边手势 / 通知 / URL / 图标分屏等**其它入口完全不受影响**。

## 安装

1. 已安装 ScreenCore 2.0.5；
2. 选择对应 deb（rootless / roothide）安装；
3. respring 或重启 SpringBoard。

## 验证

- 全屏 App → ARC 点「全屏转ScreenCore分屏」→ 应弹出**小窗口**且可任意拖动位置；
- 日志：`log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'` 应出现 `shrink frame ... -> ...`。

## 已知限制

- 尺寸比例写死在 `SC_FLOAT_WIDTH_RATIO` / `SC_FLOAT_MAX_HEIGHT_RATIO`，需改代码重编；后续可接上插件自带的 `splitDefaultWindowSizePercent` 偏好。
- 部分 App 自适应尺寸可能强制回弹到 Scene 的最小尺寸，表现会比设定值大。
- 若该 App 之前已经记住过大小位置（`记忆大小/位置` 开启），本版会把**记忆帧**也一起收缩，但不重写记忆值。

## 逆向备忘（ScreenCore.dylib 2.0.5，arm64 切片，未滑动地址）

| 地址 | 符号 / 选择器 |
|---|---|
| `0x113a4` | `_SCFullscreenToSplitToolPerform` |
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x46cf4` | `-sc_openSplitForBundleIdentifier:presentationSourceRect:` |
| `0x47f60` | `-sc_openSplitForBundleIdentifier:targetIdentifier:transitionContext:nativeSceneHandle:validation:nativeLaunch:presentationSourceRect:` |
| `0x43c1c` | `-sc_defaultContainerFrameForReferenceSize:hostBounds:` |
| `0x43f1c` | `-sc_rememberedFrameForTargetIdentifier:hostLandscape:contentLandscape:referenceSize:fallback:` |
| `0x463ac` | `-sc_dockSession:fromCorner:` |
| `0x3a384` | `-sc_targetFramesForSide:`（侧贴槽位） |
| `0x3d770` | `-sc_layoutDockedItemsAnimated:`（侧贴重排） |
| `0x48f98` | `-sc_promoteFrontmostFloatingSceneToFullscreen` |
