# ScreenCoreDock v0.3.6

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.6`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版改动：只清理，不改行为

通知中心不收回侧贴已验证可用。本次把测试期间临时加的东西全删了，功能不变。

### 删除内容

| 删除项 | 原因 |
| --- | --- |
| `sc_dumpCoverSheetDiagnostics()` 与 5 秒后的窗口类名 dump | 纯诊断，用于校准窗口类名 |
| `hook_restoreRecord`（restoreRecordToNormalFrame 只记日志） | 只记日志，无任何行为，验证已结束 |
| `targetFramesForSide` 里逐张卡的 `landscape frames ... A -> B` | 每次重排刷屏，无诊断价值 |
| `sc_closeSession` / `sc_closeAllSessions` / `undockSession` 里的 `notification center shown: skip ...` 日志 | 行为保留，日志删掉 |
| 顶部大段版本演进注释（v0.1.x / v0.2.x 逐条历史） | 换成一句话功能清单 |
| 接口声明里未使用的 `sc_restoreRecordToNormalFrame:animated:completion:` | 随 hook 一并移除 |

### 保留内容（就是功能本体）

1. `sc_openFrontmostApplicationAsSplitFromSourceRect:` → 打开后补一次 dock；
2. `sc_dockSession:fromCorner:` → 横屏被拒时临时顶竖屏重入，再兜底 DockManager；
3. `activeHostOrientation` → 配合上面的临时覆盖；
4. `sc_activeHostOrientationDidChange:duration:` → 转横屏后 0.1s 双侧 relayout；
5. `sc_restoreAllDockedSessionsAnimated:` → 通知中心在场 / 转横屏时跳过；
6. `sc_targetFramesForSide:` → 横屏 0.5 缩放 + 左右间距对齐 + 顶部 1/4 间距；
7. `sc_handleFullscreenTap:` → 左手势区改为关闭浮窗；
8. `sc_undockSession:animated:` / `sc_closeSession:animated:` / `sc_closeAllSessions` → 通知中心在场时跳过。

### 剩余日志（只有失败/关键路径）

```
v0.3.6 loaded in SpringBoard
hooked: open + dockSession + orientation + restoreAllDocked + targetFrames + leftRegionClose + keepOnCoverSheet
dock corner=1 ok=1
landscape dock ok via forced-orientation retry
sc_dockSession:fromCorner: threw ...
```
