# ScreenCoreDock v0.1.3

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.3`
- 架构：`iphoneos-arm64`（fat，含 arm64 + arm64e 切片）
- 打包方案：`roothide`

## 本版改动：贴边吸附 + 离边自由摆放

工具「全屏转ScreenCore分屏」→ 前台应用变为**侧贴小卡片浮窗**，交互规则：

- **松手贴近左/右边缘** → 清除自由位置，回到插件原本的侧贴槽位吸附逻辑（按顺序排回边缘）；
- **松手偏离两侧边缘** → 停在当前落点，任意位置自由移动，不再回槽位。

### 为什么原来的侧贴不能自由移动

侧贴卡片的坐标不是绝对坐标，而是 `(side, order)` 的函数：

```
拖拽结束  -sc_moveDraggingRecord:toSide:center:
        → -sc_updateNormalizedYForOrder:     // 落点 Y 被归一化成 order 序号
        → -sc_layoutSide:animated:completion:
           → -sc_targetFramesForSide:          // 按 (side, order) 重算所有槽位
           → -sc_applyFrame:toRecord:          // 逐个应用，卡片回到槽位
```

### 本版补丁点（3 个 hook）

| Hook | 作用 |
|---|---|
| `-sc_moveDraggingRecord:toSide:center:` | 用传入的 center（hostRootView 坐标系）判断是否贴边；贴边清掉自由 frame，离边按落点 center + 卡片现有尺寸构造自由 frame 存到 record 关联对象 |
| `-sc_targetFramesForSide:` | 槽位表里「有自由 frame」的 record，槽位换成自由 frame |
| `-sc_applyFrame:toRecord:` | 落帧前兜底：有自由 frame 就用自由 frame 覆盖传入帧 |

贴边判定阈值 `SC_EDGE_SNAP_INSET`（默认 90pt），在 `Tweak.xm` 顶部可改。

## 安装

1. 已安装 ScreenCore 2.0.5；
2. 安装 roothide deb；
3. respring 或重启 SpringBoard。

## 验证与日志

- 全屏 App → ARC 点「全屏转ScreenCore分屏」→ 变成侧贴小卡片；
- 拖到屏幕中间松手 → 应停在那里；拖回左/右边缘松手 → 应吸附回原槽位；
- 日志：`log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'`，应看到：
  - `hooked (mode=2, dockClass=..., edgeInset=90)`
  - `drop free (...) -> free frame {...}` 或 `drop near edge (...) -> snap to slot`
  - `free frame applied for record ... -> {...}` / `applyFrame free ...`

## 已知限制 / 待真机确认

- 拖到屏幕外侧（插件判定为“向外拖关闭”）时仍会关闭，本版未改 `sc_shouldDismissRecordOutward:center:velocity:`。
- 卡片尺寸仍由原插件决定（不可调整大小）；本版只改位置。
- 自由位置不持久化：record 被销毁（关闭/展开/重开）后回到槽位；如需跨重启记忆，下版写进 prefs。
- 多个卡片各自自由摆放，但 z 序仍由插件按 order 维护。
- 本版尚未经真机验证；若竖直方向仍被夹在边缘竖条内，说明 `didMoveToCenter` 收尾处还有一层内联的 y 向夹紧，需要再加 hook，日志里能据此判断。

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
| `0x3e5e4` | `-sc_moveDraggingRecord:toSide:center:` |
| `0x3f200` | `-sc_dockedFloatingItemView:didMoveToCenter:state:velocity:` |
