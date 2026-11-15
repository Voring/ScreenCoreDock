# ScreenCoreDock v0.1.6

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.6`
- 依赖：`com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e 双切片）
- 打包方案：`roothide`

## 本版改动

### 1. 修复：v0.1.5 把「转侧贴浮窗」改没了

v0.1.5 删掉了打开后的 `-sc_dockSession:fromCorner:` 调用，导致工具回到原始分屏行为，侧贴浮窗功能消失。
本版在默认模式下恢复该调用，行为等同 v0.1.0：打开后停靠到侧边（`splitDefaultDockSide` 决定左右）。

### 2. 新增：自由浮窗模式（改用插件自己的「取消停靠」例程）

不做 `setDisplayState` 硬改，改为调用插件内的
`-sc_restoreRecordToNormalFrame:animated:completion:`（0x3c7e0）：
它会把 record 放进 `restoringRecords`、`setDisplayState:3`、动画回 `normalFrame`，
这是插件自己「把贴边卡片还原成普通浮窗」的正规路径。

实现细节：

- 打开成功后等 0.25s，让 dock 状态落地；
- 取 `-dockManager`，遍历 `-sc_recordsForSide:`（side 1/2），按 `-[record session] == activeSession` 精确匹配，只处理本次打开的那一个；
- 对命中 record 调用 `sc_restoreRecordToNormalFrame:animated:NO completion:nil`；
- 兜底再 `setDisplayState:3`。

### 3. 开关（不需要重编译）

偏好域 `com.voring.screencoredock`，键 `FreeFloatMode`：

| 值 | 行为 |
|---|---|
| 缺省 / `0` | 侧贴浮窗（v0.1.0 行为，默认） |
| `1` | 取消停靠 → 普通浮窗（自由拖动） |

写入方式（SSH 或 Filza 终端）：

```sh
defaults write com.voring.screencoredock FreeFloatMode -bool YES
killall -9 SpringBoard
```

关闭自由浮窗：

```sh
defaults write com.voring.screencoredock FreeFloatMode -bool NO
killall -9 SpringBoard
```

## 两个模式的取舍（事实，不是猜测）

侧贴（displayState 1）用 `(side, order)` 槽位模型，坐标由布局重算决定，**原生不支持脱离侧边自由摆放**；
普通浮窗（displayState 3）才是自由拖动的状态。二者互斥，同一个 record 不能同时具备。
所以本版做成开关，而不是把两种行为硬塞进同一个状态。

## 验证日志

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

期望输出：

- 启动：`hooked (mode=dock(0))` 或 `hooked (mode=free-float(1))`
- 每次触发：`open ok, mode=...`
- 模式 0：`dock path: corner=1 ok=1 session=0x...`
- 模式 1：`free path: restored record 0x... (side=1)` + `free path: displayState 1 -> 3`

## 真机待确认

1. 模式 0 是否恢复侧贴浮窗（回到 v0.1.0 手感）；
2. 模式 1 窗口是否变成可任意拖动、松手不回侧边的普通浮窗；
3. 模式 1 若窗口尺寸变大，把 `free path: displayState ...` 附近日志发我。

## 逆向备忘（arm64 切片，未滑动地址）

| 地址 | 选择器 |
|---|---|
| `0x113a4` | `_SCFullscreenToSplitToolPerform` |
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x46cf4` | `-sc_openSplitForBundleIdentifier:presentationSourceRect:` |
| `0x463ac` | `-sc_dockSession:fromCorner:`（内部 `setDisplayState:1`） |
| `0x462e4` | `-sc_dockSessionForSingleActiveWindow:` |
| `0x3c7e0` | `-sc_restoreRecordToNormalFrame:animated:completion:`（`setDisplayState:3`） |
| `0x3a170` | `-sc_recordsForSide:` |
| `0x3a384` | `-sc_targetFramesForSide:` |
| `0x3ac70` | `-sc_applyFrame:toRecord:` |
| `0x3e5e4` | `-sc_moveDraggingRecord:toSide:center:` |
| `0x3f200` | `-sc_dockedFloatingItemView:didMoveToCenter:state:velocity:` |
