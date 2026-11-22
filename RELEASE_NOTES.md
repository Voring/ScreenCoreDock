# ScreenCoreDock v0.4.2

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.4.2`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版：移除通知中心保留拦截

自 v0.3.5 起为了“下拉通知中心不清除浮窗”加了一整套拦截，实测在真机上不生效，本版整块移除。

### 删除

- `sc_windowClassNameContains()`：遍历 `UIApplication.windows` 按类名匹配 `CoverSheet` / `NotificationCenter`；
- `sc_deviceLocked()` 与 libnotify 的 `notify_register_check` / `notify_get_state` 声明（只为区分锁屏态而存在）；
- `sc_coverSheetPresented()`；
- `hook_undockSession`、`hook_closeSessionAnimated`、`hook_closeAllSessions` 三个拦截函数；
- `hook_restoreAllDocked` 里的 `sc_coverSheetPresented()` 提前返回；
- 对应的 `SCFloatingSceneManager` / `SCFloatingDockManager` 接口声明与 orig 指针；
- `#include <string.h>`（`strstr` 已无使用者）。

### 结果

通知中心与锁屏下的收起行为完全交回 ScreenCore 原生，插件只负责“全屏 → 侧贴浮窗”及其余四项行为。不新增任何判定。

## 既有行为（未改动）

- 打开分屏后补一次 dock，corner 取 `splitDefaultDockSide`；
- 横屏也能转侧贴，转进横屏不强制收回；
- 横屏已侧贴应用保留位置与 1/4 缩放（`LandscapeDockScale` 默认 0.5）；
- 左/右/下侧点击关闭浮窗，顶部点击转全屏；左侧手势区为关闭；
- 拖动浮窗到底部中央窄条（高 75pt，宽 134pt）松手转全屏。
