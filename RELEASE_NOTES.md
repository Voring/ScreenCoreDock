# ScreenCoreDock v0.4.1

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.4.1`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版只做精简，行为不变

### 删除

- 启动 0.5s 后遍历可见窗口的诊断 dump（`visible windows: ...`）；
- 锁屏期间 `closeAllSessions` / `restoreAllDocked` 两条 `passthrough` 诊断日志；
- 手势区 hook 里多余的 orig 空指针判断。

### 合并

- 左侧手势区两个并列 `@try` 合并为一层；
- 横屏重排循环内逐次 `@try` 合并为一层。

### 保留

- 所有对 ScreenCore 私有方法调用的 `@try` 保护、方向切换标记、锁屏状态判定、通知中心保留判定、横屏缩放重排、拖底转全屏逻辑一律未动。

## 既有行为

- 左/右/下侧点击关闭浮窗，顶部点击转全屏；左侧手势区为关闭；
- 下拉通知中心保留侧贴，锁屏时收起；
- 拖动浮窗到底部中央窄条（高 75pt，宽 134pt）松手转全屏；
- 横屏已侧贴应用不被强制下掉，横屏侧贴位置与 1/4 缩放保留。
