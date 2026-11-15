# ScreenCoreDock v0.3.7

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.7`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版改动：修复 v0.3.5 引入的关闭/放大手势回归

### 问题

v0.3.5 起：浮窗左/右/下侧点击不再关闭浮窗，点击侧贴也不再放大浮窗。

### 原因

通知中心在场判定遍历 `[UIApplication sharedApplication].windows` 时，把**收起后仍留在数组里的隐藏 CoverSheet 窗口**也算成在场，导致 `sc_closeSession:animated:` / `sc_undockSession:animated:` 等正常关闭、放大调用被无条件跳过。

### 修复

- 窗口类名匹配前先跳过 `isHidden == YES` 的窗口；
- 启动 0.5s 后打一条可见窗口清单（类名 / hidden / level），用于确认到底命中了哪个类。

### 行为保持不变

下拉通知中心时侧贴仍不被收回；横屏已侧贴应用不被强制下掉；横屏侧贴位置与 1/4 缩放保留；左侧手势区关闭浮窗。

### 装完请回传

日志路径：`/var/mobile/Library/Logs/ScreenCoreDock.log`（不可写则 `/tmp/ScreenCoreDock.log`），关注启动后那条：

```
visible windows: ...
```

如果本版关闭/放大仍失效，把这一行连同复现步骤回传。
