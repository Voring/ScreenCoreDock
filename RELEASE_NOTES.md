# ScreenCoreDock v0.4.3

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.4.3`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 本版：默认侧贴方向改为右侧

### 改动

- `sc_defaultDockCorner()` 固定返回 `corner 2`，打开分屏后补 dock 时贴屏幕右侧；
- 不再读取 `com.susudear.screencore` 的 `splitDefaultDockSide`，方向由插件直接决定；
- 要改回左侧只需把该函数里的 `2` 改成 `1`。

### 未改动

- 横屏转侧贴、转进横屏不强制收回、横屏 1/4 缩放与间距重排；
- 左侧手势区关闭、顶部转全屏、右侧/下侧关闭；
- 拖到底部中央窄条（75pt × 134pt）转全屏；
- 通知中心与锁屏收起行为交回 ScreenCore 原生。
