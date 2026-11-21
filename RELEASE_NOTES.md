# ScreenCoreDock v0.4.0

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.4.0`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版改动：锁屏不再保留侧贴与浮窗

v0.3.5 起的「CoverSheet 在场就保留侧贴」判定，会连带把锁屏也当成通知中心，导致锁屏后侧贴和浮窗被留着。本版把这一条拆开：

- 锁屏态下不再走保留判定，侧贴与浮窗按原生行为收起；
- 下拉通知中心时仍然保留（不清除）；
- 其余行为一律不变。

### 实现

- 用 libnotify 的 `com.apple.springboard.lockstate` 键值读锁屏状态（`notify_register_check` / `notify_get_state`），不触碰任何 SpringBoard 私有类或单例；
- 判定入口 `sc_coverSheetPresented()` 增加一行前置分支：锁屏直接返回 NO；
- 锁屏期间若系统调 `sc_closeAllSessions` 或 `sc_restoreAllDockedSessionsAnimated:`，日志各记一行 `locked -> ... passthrough`。

### 既有行为保持不变

- 左/右/下侧点击关闭浮窗，顶部点击转全屏；左侧手势区为关闭；
- 拖动浮窗到底部中央窄条（高 75pt，宽 134pt）松手转全屏；
- 横屏已侧贴应用不被强制下掉，横屏侧贴位置与 1/4 缩放保留。

### 日志

```
locked -> closeAllSessions passthrough
locked -> restoreAllDocked passthrough
drag-to-bottom-center -> fullscreen, frame={{...}}
```
