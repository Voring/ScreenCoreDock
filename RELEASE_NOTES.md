# ScreenCoreDock v0.1.7

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.7`
- 依赖：`com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 三种模式

偏好域 `com.voring.screencoredock`，键 `FreeFloatMode`：

| 值 | 行为 |
|---|---|
| 缺省 / `0` | 侧贴浮窗，沿侧边自上而下堆叠（v0.1.0 行为） |
| `1` | 取消停靠 → 普通浮窗（displayState 3） |
| `2` | **dock 内任意位置**：仍是侧贴状态，卡片停在拖拽落点，不再被"自上而下堆叠"拉回 |

```sh
defaults write com.voring.screencoredock FreeFloatMode -int 2
killall -9 SpringBoard
```

## 为什么"任意槽位"不存在（反汇编依据）

- `-sc_updateNormalizedYForOrder:`（0x3e52c）：遍历数组，对每条 record 写
  `normalizedY = (i+1)/(count+1)`。**完全不读落点 Y**；`normalizedY` 只用于排序。
- `-sc_targetFramesForSide:`（0x3a384）：纵向没有槽位参数，Y 是逐条累加：
  `0x3aa84: y = y + (gap + height)`，`gap = (count>1 ? 18 : 0)`。
  所以纵向只有"堆叠"，不存在可选的槽位序号。

结论：要让卡片停在任意位置，只能覆盖 `-sc_targetFramesForSide:` 返回的帧表，并摁住收尾层。

## 模式 2 的三枚 hook

1. `-sc_moveDraggingRecord:toSide:center:`
   - 记下落点中心（hostRootView 坐标系）到 record 关联对象 `kFreeCenterKey`；
   - 同时把 `side` 钉住（`kPinnedSide`），阻止 `0x3e790` 按 `center.x` 与帧 x 比较反复翻转 side —— 这是之前"左右闪烁"的直接原因。
2. `-sc_targetFramesForSide:`
   - 对带自由中心的 record，把槽位**平移**到该中心；
   - **尺寸沿用槽位尺寸**（`-sc_applyFrame:toRecord:` 内部按 目标帧/normalFrame 尺寸比算缩放，改大尺寸会把卡片放大数倍，这是 v0.1.3 满屏 bug 的根因）；
   - 只处理该 record 自己那一侧（按 `kPinnedSide` 过滤），避免另一侧把卡片重复摆一遍。
3. `-sc_dockedFloatingItemView:didMoveToCenter:state:velocity:`
   - 命中自由记录时**不调 orig**：它内部会再调 `moveDraggingRecord`、内联算槽位 x、对 y 夹紧，然后直接 `setCenter:` 到 itemView(0x3f74c) 与 containerView(0x3f77c)，绕过 applyFrame；
   - 直接按自由中心 `setCenter:`，保持卡片位置。

## 真机预期

- 模式 2 下把卡片拖到任意位置松手，应停在原地（可不在边缘、可不按上下顺序）；
- 不再左右闪烁；
- 尺寸不变。

若无效果，日志会直接指出断点，按下面关键字看：

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

- `hooked (mode=2, dockClass=...)`
- `drag drop record=... pinned=... center=...`（说明 hook 1 命中）
- `frames side=1 record=... A -> B`（说明 hook 2 命中，看 B 是否为你落点）
- `didMove swallowed record=... -> center=...`（说明 hook 3 命中）

若 `frames` 那行根本没出现，说明该侧布局没被重建，需要在 `-sc_applyFrame:toRecord:` 再兜一层；
若出现但卡片仍回弹，说明还有别的 `setCenter:` 路径，把 `didMove swallowed` 后面的日志发我。

## 逆向备忘（arm64，未滑动地址）

| 地址 | 选择器 |
|---|---|
| `0x113a4` | `_SCFullscreenToSplitToolPerform` |
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x463ac` | `-sc_dockSession:fromCorner:` |
| `0x3c7e0` | `-sc_restoreRecordToNormalFrame:animated:completion:` |
| `0x3e52c` | `-sc_updateNormalizedYForOrder:` |
| `0x3e5e4` | `-sc_moveDraggingRecord:toSide:center:` |
| `0x3a384` | `-sc_targetFramesForSide:` |
| `0x3ac70` | `-sc_applyFrame:toRecord:` |
| `0x3ab14` | `-sc_dockTransformForRecord:targetFrame:` |
| `0x3f200` | `-sc_dockedFloatingItemView:didMoveToCenter:state:velocity:` |
| `0x3f664` | 收尾层内部调 `moveDraggingRecord` |
| `0x3f74c` / `0x3f77c` | 收尾层直接 `setCenter:`（itemView / containerView） |
