# ScreenCoreDock v0.1.2

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.2`
- 架构：`iphoneos-arm64`（含 arm64 + arm64e）
- 打包方案：`rootless` / `roothide`

## 本版改动

工具「全屏转ScreenCore分屏」→ 前台应用变为**侧贴小卡片浮窗**，并且**拖到哪就停在哪**（不再强制回到屏幕两侧、不再按顺序排成一条）。

### 为什么原来的侧贴不能自由移动

侧贴卡片的坐标不是绝对坐标，而是 `(side, order)` 的函数：

```
拖拽结束  -sc_moveDraggingRecord:toSide:center:
        → -sc_updateNormalizedYForOrder:     // 落点 Y 被归一化成 order 序号
        → -sc_layoutSide:animated:completion:
           → -sc_targetFramesForSide:          // 按 (side, order) 重算所有槽位
           → -sc_applyFrame:toRecord:          // 逐个应用，卡片回到槽位
```

所以拖拽只能改顺序/换边，松手必回原位。这是布局模型，不是某个常量。

### 本版怎么改的

在**算槽位**这个唯一收口处打补丁，并记录用户拖到的位置：

| Hook | 作用 |
|---|---|
| `-sc_moveDraggingRecord:toSide:center:` | 落地前先抓下 itemView 当时的绝对 frame，存到该 record 的关联对象 |
| `-sc_targetFramesForSide:` | 算完槽位表后，把「有自定义位置」的 record 的槽位换成它的自定义 frame |

因为 `sc_layoutSide:` 每次重排都会经过 `sc_targetFramesForSide:`，自定义位置在旋转、新增/关闭窗口、respring 后的重排中都能保留（直到该 record 被销毁）。

### 编译期模式

```objc
#define SC_DOCK_MODE 2   // 0=小尺寸自由浮窗 / 1=侧贴固定槽位 / 2=侧贴+自由摆放（默认）
```

## 安装

1. 已安装 ScreenCore 2.0.5；
2. 选对应 deb（rootless / roothide）安装；
3. respring 或重启 SpringBoard。

## 验证

- 全屏 App → ARC 点「全屏转ScreenCore分屏」→ 变成侧贴小卡片；
- 把小卡片拖到屏幕中间/任意位置松手 → **应停在那里**，不再弹回边缘；
- 日志：`log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'`，应看到
  `remember free frame {...}` 与 `free frame applied for record ... -> {...}`。

## 已知限制 / 待你在真机确认

- 拖到屏幕外側（插件判定为“向外拖关闭”）时仍会关闭，这是 `sc_shouldDismissRecordOutward:center:velocity:` 的行为，本版未改。
- 自定义位置目前**不持久化**：record 被销毁（关闭/展开/重开）后回到槽位；如果需要跨重启记忆，需要把 frame 写进 prefs，可在下一版加。
- 多个卡片可各自自由摆放，但 z 序仍由插件按 order 维护，可能出现遮挡顺序不合预期。
- 本版完全未经真机运行验证（只做了静态逆向分析 + 编译），首次测试请先看日志。

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
