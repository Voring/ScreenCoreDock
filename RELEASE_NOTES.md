# ScreenCoreDock v0.2.1

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.2.1`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

逻辑仍是 **v0.1.0 基线**（打开分屏 -> 补一次 dock），叠加横屏相关的四项放开与两项几何修正。

### 横屏限制一（v0.1.8 已解）

`-sc_dockSession:fromCorner:`（0x463ac）进门即判方向，只接受 1/2，横屏直接 `return NO`（0x463e4）。下层 `SCFloatingDockManager` 同名方法（0x3bde4）不看方向。

修法：hook 上层，失败且方向 ≥3 时临时把 `activeHostOrientation` 顶成 1 重入，仍失败直接调 DockManager 层。

### 横屏限制二（v0.1.9 已解）

`-sc_activeHostOrientationDidChange:duration:`（0x42ca8）尾部，方向变横屏就 `sc_restoreAllDockedSessionsAnimated:` 把所有侧贴收回（0x42ee0）。

修法：方向切换期间打标记，hook `-sc_restoreAllDockedSessionsAnimated:`，标记为真且 `hostOrientation >= 3` 时跳过。

### 横屏点四角不进侧贴（本版 v0.2.1 修）

**根因**：`-sc_handleDockTap:`（0x386b0）在 0x38738 处比较容器 bounds：

```
0x38730  bl    bounds
0x38734  bl    CGRectGetHeight
0x38738  fcmp  d8, d0        ; 宽 vs 高
0x3873c  b.le  -> 0x38760    ; 竖屏才继续
0x38740  ...   -> 0x387d0    ; 宽 > 高（横屏）直接返回，不发 dock 请求
```

所以横屏下点浮窗四个角没有反应；能侧贴只是因为 v0.1.9 保住了「竖屏贴好再转横屏」的记录。

**修法**：hook 该视图的 `-sc_handleDockTap:`（按选择器找到同时实现 `sc_handleDockTap:` 与 `cornerResizeTouchRegions` 的类），竖屏照原方法走；横屏且未 docked 时，复刻原方法末尾那一步：

```
[[self delegate] sc_floatingContainerView:self didRequestDockFromCorner:[[gesture view] tag]]
```

后续仍走已 hook 的 `-sc_dockSession:fromCorner:`，于是横屏直接点角就能落成侧贴。

### 横屏卡片过大（v0.2.0 修）

**根因**：`-sc_targetFramesForSide:`（0x3a384）算尺寸时

- 宽度 = `hostWidth * 0.23`，夹在 `[88, 170]`（常量 0x8c0c0=0.23、0x8c0c8=170.0）；
- 高度 = 宽度 × **record.normalFrame 的高/宽比**（0x3a650~0x3a668 取 `CGRectGetHeight/CGRectGetWidth`）。

横屏下 `normalFrame` 仍是竖屏比例（高/宽 > 1），高度被推成接近整屏高。

**修法**：hook `SCFloatingDockManager -sc_targetFramesForSide:`，仅当 `hostOrientation >= 3` 时：

1. 每张卡的宽、高各乘 `scale`（默认 0.5，即面积 1/4）；
2. 用重算后的高度自上而下重新紧凑堆叠（gap = 18 × scale）；
3. 超出屏幕高度时向上夹紧；
4. 竖屏完全走原逻辑。

缩放系数可用偏好调整：

```sh
defaults write com.voring.screencoredock LandscapeDockScale -float 0.5
```

另外，转进横屏后会延时 0.1s 对左右两侧各调一次 `-sc_layoutSide:animated:completion:`，确保缩放后的帧真正落地。

### 横屏左右/顶部边距（本版 v0.2.1 修）

左右边距在插件里本来就是同一个常量 **8pt**（0x3aaec 的 `-8`、0x3aaf8 的 `+8`）；顶部用的是 `_SCFloatingPortraitTopInset`（0x33c98），而该函数在横屏（bounds 宽 > 高）时返回 **0**。

右侧看着离得远，是 v0.2.0 的问题：缩尺寸时只重算了宽高、没重算右侧 x，缩掉的一半宽度全变成右侧空隙（`8 + 0.5×旧宽 ≈ 93`）。

**修法**：横屏重排时统一左右间距，顶部再叠一个状态栏高度：

- 左右间距 `margin = 8 + 旧宽 × (1 - scale)`（即横屏右侧原本看到的那个间距）；
- 左侧照拄同一值：`x = minX + margin`；右侧按新宽度重算：`x = maxX - margin - 新宽`；
- 顶部 `topGap = margin + 状态栏高度`（优先读插件 `splitPortraitTopSpacing`，取不到用系统状态栏高度，再兜底 44）。

### 编译修复

上一版对 `id` 直接发 `sc_floatingContainerView:didRequestDockFromCorner:` 报 `no known instance method`，本版补了 NSObject 分类声明，改用 `(NSObject *)delegate` 发送。

## 真机验证

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

- 横屏后应看到 `landscape frames side=1 scale=0.50 ... -> ...`，对比前后尺寸应约为一半；
- 以及 `landscape relayout done`；
- 横屏点四角应看到 `landscape dock tap corner=N, forward to sceneManager`，随后 `dock corner=... ok=1`；
- 竖屏不应出现 `landscape frames` / `landscape dock tap` 这些行。

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
| `0x3ab14` | `-sc_dockTransformForRecord:targetFrame:` |
| `0x3fb28` | `-hostOrientation` |
| `0x386b0` | `-sc_handleDockTap:`（横屏 0x38738 宽>高直接 return） |
| `0x4931c` | `-sc_floatingContainerView:didRequestDockFromCorner:` |
| `0x33c98` | `_SCFloatingPortraitTopInset`（横屏返回 0） |
