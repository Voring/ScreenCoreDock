# ScreenCoreDock v0.2.0

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.2.0`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

逻辑仍是 **v0.1.0 基线**（打开分屏 -> 补一次 dock），叠加横屏相关的三项放开与一项尺寸修正。

### 横屏限制一（v0.1.8 已解）

`-sc_dockSession:fromCorner:`（0x463ac）进门即判方向，只接受 1/2，横屏直接 `return NO`（0x463e4）。下层 `SCFloatingDockManager` 同名方法（0x3bde4）不看方向。

修法：hook 上层，失败且方向 ≥3 时临时把 `activeHostOrientation` 顶成 1 重入，仍失败直接调 DockManager 层。

### 横屏限制二（v0.1.9 已解）

`-sc_activeHostOrientationDidChange:duration:`（0x42ca8）尾部，方向变横屏就 `sc_restoreAllDockedSessionsAnimated:` 把所有侧贴收回（0x42ee0）。

修法：方向切换期间打标记，hook `-sc_restoreAllDockedSessionsAnimated:`，标记为真且 `hostOrientation >= 3` 时跳过。

### 横屏卡片过大（本版 v0.2.0 修）

**根因**：`-sc_targetFramesForSide:`（0x3a384）算尺寸时

- 宽度 = `hostWidth * 0.23`，夹在 `[88, 170]`（常量 0x8c0c0=0.23、0x8c0c8=170.0）；
- 高度 = 宽度 × **record.normalFrame 的高/宽比**（0x3a650~0x3a668 取 `CGRectGetHeight/CGRectGetWidth`）。

横屏下 `normalFrame` 仍是竖屏比例（高/宽 > 1），高度被推成接近整屏高，卡片变成一大块。

**修法**：hook `SCFloatingDockManager -sc_targetFramesForSide:`，仅当 `hostOrientation >= 3` 时：

1. 每张卡的宽、高各乘 `scale`（默认 0.5，即面积 1/4）；
2. 用重算后的高度自上而下重新紧凑堆叠（gap = 18 × scale），x 沿用插件算好的贴边位置；
3. 超出屏幕高度时向上夹紧；
4. 竖屏完全走原逻辑，不干预。

缩放系数可用偏好调整（不写则用 0.5）：

```sh
defaults write com.voring.screencoredock LandscapeDockScale -float 0.5
```

另外，转进横屏后会延时 0.1s 对左右两侧各调一次 `-sc_layoutSide:animated:completion:`，确保缩放后的帧真正落地（否则容器帧可能停留在旋转前的整屏尺寸）。

## 真机验证

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

- 横屏后应看到 `landscape frames side=1 scale=0.50 ... -> ...`，对比前后尺寸应约为一半；
- 以及 `landscape relayout done`；
- 竖屏不应出现 `landscape frames` 这行。

若尺寸仍偏大/偏小，直接改 `LandscapeDockScale`（0.2~1.0）即可，无需重编。

## 逆向备忘（arm64，未滑动地址）

| 地址 | 选择器 / 函数 |
|---|---|
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x463ac` | `-sc_dockSession:fromCorner:`（方向守卫 0x463e4） |
| `0x3bde4` | `SCFloatingDockManager -sc_dockSession:fromCorner:` |
| `0x42ca8` | `-sc_activeHostOrientationDidChange:duration:`（横屏收回 0x42ee0） |
| `0x3d13c` | `-sc_restoreAllDockedSessionsAnimated:` |
| `0x3a384` | `-sc_targetFramesForSide:`（宽度 0.23×hostW / 高度按 normalFrame 比例） |
| `0x3b1fc` | `-sc_layoutSide:animated:completion:` |
| `0x3ab14` | `-sc_dockTransformForRecord:targetFrame:`（缩放 = min(目标宽/原宽, 目标高/原高)） |
| `0x3fb28` | `-hostOrientation` |
