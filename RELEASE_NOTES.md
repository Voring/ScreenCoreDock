# ScreenCoreDock v0.1.8

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.1.8`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

### 1. 全量回退到 v0.1.0

Tweak.xm 只保留 v0.1.0 的两条逻辑：

- hook `-sc_openFrontmostApplicationAsSplitFromSourceRect:`，原方法返回后取 `activeSession`；
- 调 `-sc_dockSession:fromCorner:`（corner 按 `splitDefaultDockSide`：0→1、1→2），失败再走 `-sc_dockSessionForSingleActiveWindow:` 兜底。

已删除（v0.1.1~v0.1.7 的全部内容）：

- `FreeFloatMode` 三态开关与相关偏好读取；
- 覆盖 `-sc_targetFramesForSide:` 帧表；
- hook `-sc_moveDraggingRecord:toSide:center:`、`-sc_dockedFloatingItemView:didMoveToCenter:state:velocity:`；
- 自由中心 / 钉住 side 的关联对象、`sc_restoreRecordToNormalFrame:` 取消停靠路径。

即：不再有"任意位置摆放""侧边吸附""取消停靠"这些分支，行为与 v0.1.0 一致。

### 2. 横屏修复（本版唯一新增）

**问题**：应用处于横屏时，「全屏转侧贴浮窗」不生效，窗口仍是居中大分屏窗。

**根因**（反汇编 `-sc_dockSession:fromCorner:`，0x463ac）：

```
0x463e0  bl    activeHostOrientation
0x463e4  sub   x8, x0, #1
0x463e8  cmp   x8, #1
0x463ec  b.hi  0x46518                     ; return NO
```

方向值只接受 1（竖屏）/ 2（倒竖屏），3、4（横屏）直接返回 NO，函数体其余部分根本不执行。所以横屏下 dock 从未发生。

但它下层的 `SCFloatingDockManager -sc_dockSession:fromCorner:`（0x3bde4）没有任何方向判断，只校验传入 frame 合法（0x3b0a0 检查 null / empty / NaN / 宽高 > 1），校验通过就建 record、setFrame、addSubview、setDisplayState、setDocked。

**修法**：hook manager 层的 `-sc_dockSession:fromCorner:`：

1. 先按原逻辑调用；成功直接返回；
2. 失败且 `activeHostOrientation >= 3`（横屏）时，临时把 `activeHostOrientation` 顶成 1，重入原方法一次，让插件自己走完整侧贴流程（`prepareForContainerGeometryTransition`、`finishPresentation`、`saveFrame`、`dockManager` dock 全都在原方法里）；
3. 重入仍失败，则直接调 `SCFloatingDockManager -sc_dockSession:fromCorner:` 兜底。

对 hook 的 `activeHostOrientation` 只在重入窗口内置为 1，其余时刻透传原值，不影响插件其他方向相关逻辑。

**已知副作用**：重入时 `sc_saveFrame:forSession:forHostOrientation:contentOrientation:` 会把当前帧按竖屏档位记下来，仅影响下次旋转回来时的还原位置，不影响当次侧贴。

## 真机验证

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

- 竖屏：应看到 `dock corner=1/2 ok=1`；
- 横屏：应看到 `dock rejected in landscape(3), retry with forced portrait` 紧跟 `landscape dock ok via forced-orientation retry`。

若横屏出现 `dock rejected in portrait-N, leave as is`，说明拦截不是方向引起的（session 不 live / 已 dock / 单侧已满 4 张），把那行日志发我。

## 逆向备忘（arm64，未滑动地址）

| 地址 | 选择器 / 函数 |
|---|---|
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x46cf4` | `-sc_openSplitForBundleIdentifier:presentationSourceRect:` |
| `0x463ac` | `-sc_dockSession:fromCorner:`（manager 层，含方向守卫，0x463e4） |
| `0x462e4` | `-sc_dockSessionForSingleActiveWindow:` |
| `0x3bde4` | `SCFloatingDockManager -sc_dockSession:fromCorner:`（无方向判断） |
| `0x3b0a0` | dock 前 frame 合法性校验 |
| `0x3fb04` | `hostRootView` |
| `0x3a384` | `-sc_targetFramesForSide:`（纵向累加堆叠，无槽位参数） |
