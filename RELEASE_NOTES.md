# ScreenCoreDock v0.3.8

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.8`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版新增：拖到底部中央松手转全屏

### 触发条件

拖动浮窗（未侧贴状态）松手时，浮窗底部边缘进入屏幕底部中央窄条：

- 触发区高度：一指距离（44pt，自屏幕底边向上）；
- 触发区宽度：小横条宽度（134pt，水平居中）；
- 判定：浮窗水平中心落在窄条宽度内，且浮窗底边距屏幕底边 ≤ 44pt。

命中后走原有的全屏提升链路（`sc_handleFullscreenTap:` → 代理 `didRequestFullscreen`），与顶部手势区转全屏同一套。

### 实现

- hook 容器视图 `-sc_handleMoveGesture:`（pan 手势），原方法跑完后判断手势结束态；
- 已侧贴（`isDocked == YES`）不参与；
- 帧坐标换算到父视图（host）坐标系后再做窄条判定。

### 既有行为保持不变

- 左/右/下侧点击关闭浮窗，顶部点击转全屏；
- 左侧手势区为关闭；
- 下拉通知中心不收回侧贴；
- 横屏已侧贴应用不被强制下掉，横屏侧贴位置与 1/4 缩放保留。

### 日志

命中触发区时记录：

```
drag-to-bottom-center -> fullscreen, frame={{...}}
```

日志路径：`/var/mobile/Library/Logs/ScreenCoreDock.log`（不可写则 `/tmp/ScreenCoreDock.log`）。
