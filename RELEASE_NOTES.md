# ScreenCoreDock v0.1.5

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.5`
- 架构：`iphoneos-arm64`（fat，arm64 + arm64e 切片）
- 打包方案：`roothide`

## 本版改动

放弃「侧贴卡片自由摆放」这条路线，**移除全部侧贴（dock）排列相关逻辑**，打开后保持原生普通浮窗状态（displayState 3），沿用插件原生的拖动 / 缩放 / 记忆位置能力。

### 为什么放弃侧贴路线（v0.1.0 ~ v0.1.4 反复验证结论）

侧贴是一套独立布局模型：record 的坐标 = f(side, order)。拖拽结束会经过
`sc_moveDraggingRecord:toSide:center:` → `sc_updateNormalizedYForOrder:` →
`sc_layoutSide:animated:completion:` → `sc_targetFramesForSide:` → `sc_applyFrame:toRecord:`，
另外 `sc_dockedFloatingItemView:didMoveToCenter:state:velocity:` 收尾层还会内联按槽位夹紧 x/y 并直接 `setCenter:`，
绕过 applyFrame。硬改槽位会在两层之间被反复拉回边缘，表现为：只能沿中轴线移动、左右闪烁、回不到两侧、离边后尺寸失控放大。
这套模型与「任意位置自由摆放」目标冲突，继续 hook 性价比很低，故整体下线。

### 本版实现

- 只保留入口 hook：`-sc_openFrontmostApplicationAsSplitFromSourceRect:`；
- 打开后**不再调用** `sc_dockSession:fromCorner:`（之前用来切到侧贴 state 1）；
- 主动把容器 `setDisplayState:3`（普通浮窗），确认不进侧贴；
- 删除 v0.1.2 ~ v0.1.4 的三枚布局 hook（targetFramesForSide / moveDraggingRecord / applyFrame）与自由位置关联对象。

## 验证与日志

```
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

应看到：

- `hooked (normal floating, no dock)`
- `session=... container=... displayState <x> -> 3 (normal floating)`

**请重点反馈**：打开后的窗口能否在屏幕任意位置自由拖动、能否调整大小。
如果拖不动（仍是半屏分屏），说明该入口创建的不是可拖动浮窗，需要再找「提升为浮窗」的路径；把上面两行日志发我即可定位。

## 已知限制

- 本版不再做侧贴小卡片外观；窗口尺寸为插件默认值。
- 若原生普通浮窗本身被限制拖动，本 hook 不额外改造拖拽行为。

## 逆向备忘（arm64 切片，未滑动地址）

| 地址 | 选择器 |
|---|---|
| `0x113a4` | `_SCFullscreenToSplitToolPerform` |
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x46cf4` | `-sc_openSplitForBundleIdentifier:presentationSourceRect:` |
| `0x463ac` | `-sc_dockSession:fromCorner:`（内部 `setDisplayState:1`） |
| `0x3c8d0` | 还原普通帧：`setDisplayState:3` |
| `0x38b3c` | `displayState` / `0x38b4c` `setDisplayState:` |
| `0x3c7e0` | `-sc_restoreRecordToNormalFrame:animated:completion:` |
