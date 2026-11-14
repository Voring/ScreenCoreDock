# CI 说明

推送到 `main` 或在 Actions 页面手动 `Run workflow` 会触发 `.github/workflows/build.yml`。

- Runner：`macos-15`（Apple Silicon）
- Theos：`roothide/theos`（支持 `rootless` 与 `roothide` 两种 packaging scheme）
- SDK：仅拉取 `theos/sdks` 里的 `iPhoneOS16.5.sdk`（sparse checkout，避免整包下载）
- 矩阵：`rootless`、`roothide` 各产一份 deb
- 产物名：`ScreenCoreDock-rootless`、`ScreenCoreDock-roothide`（GitHub Actions Artifacts）

本地等价命令：

```bash
export THEOS=/opt/theos
export THEOS_PACKAGE_SCHEME=roothide
make clean && make package FINALPACKAGE=1
```
