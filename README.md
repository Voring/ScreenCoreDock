# ScreenCoreDock

把 ScreenCore 2.0.5 的系统工具 **「全屏转ScreenCore分屏」**（ARC 里的 `system-tool:fullscreen-to-screencore-split`）
从「前台应用 → 分屏浮窗（居中大窗口，可拖动可缩放）」改成「前台应用 → 侧贴浮窗（贴在屏幕两侧、固定大小的小卡片）」。

不改原 deb，用一个独立 tweak hook 住 ScreenCore 的入口方法，原逻辑跑完后立刻把刚创建的 session `dock` 到屏幕边缘。

---

## 逆向依据（ScreenCore.dylib 2.0.5，fat：arm64 + arm64e）

命令链路（arm64 切片，未滑动虚拟地址）：

| 地址 | 符号 / 选择器 | 说明 |
|---|---|---|
| `0x113a4` | `_SCFullscreenToSplitToolPerform` | 系统工具入口，参数就是一个 `CGRect`；全程只做一次调用 |
| `0x6be80` | stub → `sc_sharedManager` | 取 `SCFloatingSceneManager` 单例 |
| `0x48eb8` | `-[SCFloatingSceneManager sc_openFrontmostApplicationAsSplitFromSourceRect:]` | 实现很短：`isMainThread` → `sceneDriver.sc_frontmostApplicationBundleIdentifier` → 有值就继续 |
| `0x46cf4` | `-sc_openSplitForBundleIdentifier:presentationSourceRect:` | 上面方法的唯一出口 |
| `0x47f60` | `-sc_openSplitForBundleIdentifier:targetIdentifier:transitionContext:nativeSceneHandle:validation:nativeLaunch:presentationSourceRect:` | 巨型方法（约 `0x2d00` 字节），真正建窗口的地方 |
| `0x43c1c` | `-sc_defaultContainerFrameForReferenceSize:hostBounds:` | 默认窗口几何：`splitDefaultWindowSizePercent`（默认 76）夹在 40–100%，按 `splitAspectRatioMode` 算高、居中 |
| `0x463ac` | `-sc_dockSession:fromCorner:` | 侧贴核心：`containerView setDisplayState:1` → `sc_finishPresentationForSession:` → `sc_prepareForContainerGeometryTransitionForSession:` → `dockManager sc_dockSession:fromCorner:` |
| `0x462e4` | `-sc_dockSessionForSingleActiveWindow:` | 上面的封装，会先判 `sc_isLiveSession:` / `sc_isSessionDocked:`，corner 取自 `splitDefaultDockSide` |

关键结论：

- **「分屏浮窗」和「侧贴浮窗」不是两套窗口类型**，是同一个 `SCFloatingSceneSession` 的两种 `displayState`。
- 工具走的那条链路里**完全没有** `setDocked:` / `sc_dockSession:fromCorner:` 调用，所以窗口必定落地成「分屏浮窗」——这就是现状。
- 邻居 `0x11418` 是 `sc_promoteFrontmostFloatingSceneToFullscreen`（「分屏转全屏」），逻辑刚好对称。

## 为什么不直接改 dylib

「全屏转分屏」和 ARC / 侧边手势的「分屏启动」共用同一条开窗路径，直接改 `0x47f60` 里任何一处 frame/state 计算都会影响**所有**窗口（正常分屏、URL 跳转分屏、图标分屏）。
hook 在入口方法上，只影响这一个系统工具，其它入口行为不变——也方便随时卸载回滚。

## 构建

```bash
export THEOS=/opt/theos                    # 按实际情况
export THEOS_PACKAGE_SCHEME=roothide       # 或 rootless，见 Makefile 注释
make clean && make package
```

产物：`packages/com.voring.screencoredock_0.1.0_iphoneos-arm64.deb`（`ARCHS = arm64 arm64e`，两个切片都会产出）。

## 测试

1. 装 ScreenCore 2.0.5，再装本 tweak，respring / 重启 SpringBoard。
2. 打开任意 App 到全屏 → ARC 里点「全屏转ScreenCore分屏」。
3. 预期：该 App 从全屏**直接收成屏幕边缘的小卡片**（不是居中的大浮窗）。
4. 点一下小卡片应能展开回分屏浮窗（插件自带 expand 逻辑）。
5. 验证日志：`log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'`，应看到 `dock session=... corner=1 ok=1`。

## 可调参数

| 需求 | 改法 |
|---|---|
| 贴右侧 | 改 `sc_defaultDockCorner()` 的映射；默认跟随插件 `splitDefaultDockSide`（0 → 左，1 → 右） |
| 动画更自然（先展开再收边） | 把 `sc_dockSessionIfPossible` 包进 `dispatch_after(0.35s)`，等 presentation 完成后再 dock |
| 回退原行为 | 卸载本 tweak |

## 已知风险

- `sc_dockSession:fromCorner:` 内部会 `sc_finishPresentationForSession:`；若 presentation 刚开始就 dock，动画可能表现为「直接出现在边缘」而非从全屏收缩过去。先用默认（立即 dock）测，不理想就改用延迟方案。
- 若那一刻 `activeSession` 还没指向新 session，日志会出现 `activeSession == nil`，此时不 dock，行为退化为原版。
- 若 `sc_dockSession:fromCorner:` 返回 NO（例如 `activeHostOrientation` 不在 1/2），已内置 `sc_dockSessionForSingleActiveWindow:` 兜底。

## 备用方案：二进制补丁（不推荐）

若要直接改 dylib 本体，最小补丁点是 `_SCFullscreenToSplitToolPerform`（arm64 `0x113a4`，函数体 0x74 字节）：
改成 `sharedManager` → `sc_openFrontmostApplicationAsSplitFromSourceRect:` 成功后取 `activeSession`，再 `sc_dockSession:fromCorner:`（corner=1），约 25 条指令 / 100 字节，刚好塞进原函数体。
缺点：`LC_CODE_SIGNATURE` 失效需自行重签（`ldid -S`），arm64e 切片还要单独算地址与 PAC stub。
