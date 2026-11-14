# ScreenCoreDock v0.1.0

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.0`
- 架构：`iphoneos-arm64`（内含 arm64 + arm64e 两个切片）
- 打包方案：同时提供 `rootless` 与 `roothide` 两份 deb

## 改动说明

把 ScreenCore 2.0.5 的系统工具 **「全屏转ScreenCore分屏」**（ARC 内标识 `system-tool:fullscreen-to-screencore-split`）的行为，从

> 前台应用 → **分屏浮窗**（居中大窗口，可拖动、可缩放、可正常操作）

改为

> 前台应用 → **侧贴浮窗**（贴在屏幕两侧、固定尺寸的小卡片，点一下可展开回分屏浮窗）

### 实现方式

不修改 ScreenCore 原包，用一个独立 tweak 在 SpringBoard 内 hook 工具入口方法：

```
_SCFullscreenToSplitToolPerform (0x113a4)
  └─ -[SCFloatingSceneManager sc_openFrontmostApplicationAsSplitFromSourceRect:] (0x48eb8)
```

原逻辑先照常执行（照常创建 `SCFloatingSceneSession` 并按 `normalFrame` 呈现），拿到 `activeSession` 后立即补一次：

```
-[SCFloatingSceneManager sc_dockSession:fromCorner:]   (0x463ac)
```

`corner` 跟随插件自身的 `splitDefaultDockSide` 偏好（0 → 左侧，1 → 右侧）；若返回 NO，则兜底调用插件的 `sc_dockSessionForSingleActiveWindow:`（`0x462e4`）。

### 影响范围

仅此一个系统工具。ARC 启动、侧边手势、通知/URL/图标分屏等入口走的是同一条开窗路径，但本 tweak 只 hook 了工具专用的入口方法，**其它入口行为不变**；卸载 tweak 即完全回滚。

## 安装

1. 已安装 ScreenCore 2.0.5；
2. 按越狱环境选择对应 deb（rootless / roothide）；
3. 安装后 respring 或重启 SpringBoard。

## 验证

- 全屏 App 中点击 ARC 的「全屏转ScreenCore分屏」，应直接收成屏幕边缘的小卡片；
- 点小卡片应能展开回分屏浮窗；
- 日志：`log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'` 应出现 `dock corner=1 ok=1`。

## 已知限制

- `sc_dockSession:fromCorner:` 内部会 `sc_finishPresentationForSession:`，如果在呈现刚开始时就 dock，动画可能表现为「直接出现在边缘」而非从全屏收缩过去。若观感不佳，后续版本会改为等 presentation 完成后再 dock。
- 若点击瞬间 `activeSession` 尚未指向新会话，则不会 dock，行为退化为原版（日志会打印 `activeSession == nil`）。

## 逆向备忘（ScreenCore.dylib 2.0.5，arm64 切片，未滑动地址）

| 地址 | 符号 / 选择器 |
|---|---|
| `0x113a4` | `_SCFullscreenToSplitToolPerform` |
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x46cf4` | `-sc_openSplitForBundleIdentifier:presentationSourceRect:` |
| `0x47f60` | `-sc_openSplitForBundleIdentifier:transitionContext:nativeSceneHandle:validation:nativeLaunch:presentationSourceRect:` |
| `0x43c1c` | `-sc_defaultContainerFrameForReferenceSize:hostBounds:`（`splitDefaultWindowSizePercent` 默认 76） |
| `0x463ac` | `-sc_dockSession:fromCorner:` |
| `0x462e4` | `-sc_dockSessionForSingleActiveWindow:` |
| `0x48f98` | `-sc_promoteFrontmostFloatingSceneToFullscreen`（「分屏转全屏」反向工具） |
