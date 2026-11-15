# ScreenCoreDock v0.3.0

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.0`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

四角点击方案确认走不通，本版把它整块移除，不再尝试。其它已验证可用的行为全部保留。

### 移除的内容

- `sc_handleDockTap:` hook；
- 在 `SCFloatingContainerView` 上自建的 `UITapGestureRecognizer`；
- `sc_layoutExternalInteractionRegions` 诊断 hook；
- 所有点角链路：delegate 转发、`sc_sessionForContainerView:`、`activeSession` 兜底。

浮窗四角不再有任何监听器，点击四角不再有任何行为。

### 保留的内容

| 行为 | 来源 |
|---|---|
| 全屏转分屏 -> 补一次 dock -> 侧贴浮窗 | v0.1.0 基线 |
| 横屏也能侧贴（放开方向守卫） | v0.1.8 |
| 转入横屏不强制收回已侧贴的应用 | v0.1.9 |
| 横屏卡片缩到 1/4（`LandscapeDockScale`，默认 0.5）+ 紧凑重排 | v0.2.0 |
| 横屏左右间距对齐 | v0.2.1 |
| 横屏顶部间距为间距 + 状态栏高度的 1/4 | v0.2.3 |
| 安全模式修复（按类名取类，不遍历全类表） | v0.2.2 |

### 日志

仍然写到 `/var/mobile/Library/Logs/ScreenCoreDock.log`，本版启动行：

```
v0.3.0 loaded in SpringBoard
hooked (open + dockSession + orientation + restoreAllDocked + targetFrames), corner listeners removed
```

### 实际生效的 hook

- `SCFloatingSceneManager -sc_openFrontmostApplicationAsSplitFromSourceRect:`
- `SCFloatingSceneManager -sc_dockSession:fromCorner:`
- `SCFloatingSceneManager -activeHostOrientation`
- `SCFloatingSceneManager -sc_activeHostOrientationDidChange:duration:`
- `SCFloatingDockManager -sc_targetFramesForSide:`
- `SCFloatingDockManager -sc_restoreAllDockedSessionsAnimated:`
