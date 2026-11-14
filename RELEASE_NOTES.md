# ScreenCoreDock v0.1.4

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.4`
- 架构：`iphoneos-arm64`（fat，含 arm64 + arm64e 切片）
- 打包方案：`roothide`

## 本版要解决的 bug（v0.1.3 已装的可直接升级）

**症状**：侧贴卡片拖离两侧边缘后，卡片被放大到覆盖大半个屏幕。

**原因**：v0.1.3 把“自由位置”存成了一个完整的 `CGRect`，其中尺寸是用 `record.normalFrame` 推的。
`-sc_applyFrame:toRecord:` 内部会调 `-sc_dockTransformForRecord:targetFrame:`，这个函数按
「目标帧尺寸 ÷ normalFrame 尺寸」算视觉缩放。一旦我们给的尺寸大于 real 尺寸（normalFrame 为零或异常时就会发生），
缩放比就被放大，卡片直接糊满屏。

**修法**：自由位置只存**一个中心点**，尺寸一律沿用插件自己算好的槽位尺寸。

- `-sc_targetFramesForSide:`：把槽位 **平移**到该中心（尺寸不变）；
- `-sc_applyFrame:toRecord:`：兜底时只改原点，不碰 size；
- 新增 `sc_clampCenter`：中心点夹在 host 内，保证整张卡片不越界。

## 完整交互规则

- **松手贴近左/右边缘**（默认 90pt 内）→ 清除自由位置，回原插件侧贴槽位吸附（按顺序排列）；
- **松手偏离两侧边缘** → 卡片停在落点，任意位置自由摆放，不再回槽位；
- 卡片**尺寸不变**（插件本身不提供调整大小）；
- 自由位置不持久化，record 销毁后回槽位。

阈值在 `Tweak.xm` 顶部：`#define SC_EDGE_SNAP_INSET 90.0`。

## 安装

1. 已安装 ScreenCore 2.0.5；
2. 安装 roothide deb（覆盖升级会自动替换旧版）；
3. respring 或重启 SpringBoard。

## 验证与日志

`log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'`

应看到：

- `hooked (mode=2, dockClass=..., edgeInset=90)`
- 拖动中间松手：`drop free (side=..., center=...)`
- 拖回边缘松手：`drop near edge (...) -> snap to slot`
- 重排时：`free center applied for record ... -> {...} (slot {...})` —— 两者尺寸应一致
- `applyFrame moved {...} -> {...}` —— 新旧 rect 尺寸应一致

**如果尺寸还是变大**：把 `applyFrame moved` 与 `free center applied` 两行日志的 rect 发我，能直接看出是哪一层尺寸不对。

## 已知限制

- 拖到屏幕外侧（插件判定为“向外拖关闭”）仍会关闭，本版未改。
- 多个卡片各自自由摆放，但 z 序仍由插件按 order 维护。
- 竖直方向如仍被限制在边缘竖条内，说明 `didMoveToCenter` 收尾处还有一层内联 y 向夹紧，需再加 hook。

## 逆向备忘（arm64 切片，未滑动地址）

| 地址 | 选择器 |
|---|---|
| `0x113a4` | `_SCFullscreenToSplitToolPerform` |
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x46cf4` | `-sc_openSplitForBundleIdentifier:presentationSourceRect:` |
| `0x43c1c` | `-sc_defaultContainerFrameForReferenceSize:hostBounds:` |
| `0x43f1c` | `-sc_rememberedFrameForTargetIdentifier:hostLandscape:contentLandscape:referenceSize:fallback:` |
| `0x463ac` | `-sc_dockSession:fromCorner:` |
| `0x3a384` | `-sc_targetFramesForSide:` |
| `0x3b1fc` | `-sc_layoutSide:animated:completion:` |
| `0x3ac70` | `-sc_applyFrame:toRecord:` |
| `0x3ab14` | `-sc_dockTransformForRecord:targetFrame:` |
| `0x3e5e4` | `-sc_moveDraggingRecord:toSide:center:` |
| `0x3f200` | `-sc_dockedFloatingItemView:didMoveToCenter:state:velocity:` |
