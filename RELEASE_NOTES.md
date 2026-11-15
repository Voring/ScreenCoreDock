# ScreenCoreDock v0.1.9

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.9`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

逻辑仍是 **v0.1.0 基线**（打开分屏 -> 补一次 dock），本版只继续放开横屏侧贴的两道限制。

### 限制一（v0.1.8 已解）：横屏下 dock 入口直接拒绝

`-sc_dockSession:fromCorner:`（0x463ac）一进门判方向：

```
0x463e0  bl    activeHostOrientation
0x463e4  sub   x8, x0, #1
0x463e8  cmp   x8, #1
0x463ec  b.hi  0x46518        ; 横屏(3/4) return NO
```

只接受 1/2（竖屏系列）。下层 `SCFloatingDockManager -sc_dockSession:fromCorner:`（0x3bde4）无方向判断。

修法：hook manager 层 `sc_dockSession:fromCorner:`，失败且方向 ≥3 时临时把 `activeHostOrientation` 顶成 1 重入原方法，仍失败直接调 DockManager 层兜底。

### 限制二（本版新增）：转入横屏会把全部侧贴强制收回

`-sc_activeHostOrientationDidChange:duration:`（0x42ca8）尾部：

```
0x42ec0  cmp   x26, #1        ; x26 = 新方向 - 3
0x42ec4  b.hi  0x42eec        ; 非横屏跳过
0x42ee0  bl    sc_restoreAllDockedSessionsAnimated:
```

只要方向变成横屏，dockManager 就把所有已侧贴 session 全部 restore 回普通浮窗。这就是「横屏不允许悬挂侧贴」的第二个原因，而且它会把竖屏已贴好的卡片一起收回。

修法：

1. hook `-sc_activeHostOrientationDidChange:duration:`，进出各打一个 `sc_inOrientationChange` 标记；
2. hook `SCFloatingDockManager -sc_restoreAllDockedSessionsAnimated:`，仅当「标记为真 **且** `hostOrientation >= 3`」时直接返回、不调原方法，保留侧贴；其他调用（如手动全部收回）不受影响。

## 真机验证

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

- 横屏点「全屏转侧贴」：`dock rejected in landscape(3), retry with forced portrait` -> `landscape dock ok via forced-orientation retry`
- 旋转进横屏：`landscape entry: keep docked records (skip restoreAllDockedSessionsAnimated:)`，卡片应保持在侧边不被收回
- 旋转回竖屏：`orientation change -> 1 done`

若横屏旋转后卡片仍消失，把这段日志发我，看是 `sc_reconcileSingleActiveWindowKeepingSession:` 还是 `sc_updateHostLayout` 里另有收回路径。

## 逆向备忘（arm64，未滑动地址）

| 地址 | 选择器 / 函数 |
|---|---|
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x463ac` | `-sc_dockSession:fromCorner:`（方向守卫 0x463e4） |
| `0x462e4` | `-sc_dockSessionForSingleActiveWindow:` |
| `0x3bde4` | `SCFloatingDockManager -sc_dockSession:fromCorner:`（无方向判断） |
| `0x3b0a0` | dock 前 frame 合法性校验 |
| `0x42ca8` | `-sc_activeHostOrientationDidChange:duration:`（横屏收回侧贴 0x42ee0） |
| `0x3d13c` | `SCFloatingDockManager -sc_restoreAllDockedSessionsAnimated:` |
| `0x3fb28` | `SCFloatingDockManager -hostOrientation` |
| `0x3a384` | `-sc_targetFramesForSide:` |
