# ScreenCoreDock v0.3.10

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.10`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版改动

只调触发区手感：底部中央触发区高度由 90pt 调到 **75pt**，其余逻辑不变。

### 完整触发条件

拖动浮窗（未侧贴）松手时，浮窗底边距屏幕底边 ≤ 75pt，且浮窗水平中心落在屏幕水平中心 ±67pt（总宽 134pt，即小横条宽度）内。

命中后走 `sc_handleFullscreenTap:` → 代理 `didRequestFullscreen`，与顶部手势区转全屏同一套。

### 既有行为保持不变

- 左/右/下侧点击关闭浮窗，顶部点击转全屏；
- 左侧手势区为关闭；
- 下拉通知中心不收回侧贴；
- 横屏已侧贴应用不被强制下掉，横屏侧贴位置与 1/4 缩放保留。

### 日志

```
drag-to-bottom-center -> fullscreen, frame={{...}}
```
