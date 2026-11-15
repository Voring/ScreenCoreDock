# ScreenCoreDock v0.3.3

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.3`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## v0.3.2 日志结论

v0.3.2 真机日志（`/var/mobile/Library/Logs/ScreenCoreDock.log`）：

- 三次 `v0.3.2 loaded`，hook 全部挂上；
- 只有 `sc_closeSession:animated: called (coverSheet=0)`，没有任何 `undockSession` / `restoreAllDocked` / `restoreRecordToNormalFrame` 记录；
- `coverSheet` 恒为 0。说明两个问题：
  1. 我们当初写的 `isCoverSheetPresented` getter 很可能在这个类上不存在（或 `sharedInstance` 取不到），状态探测一直返回 NO；
  2. 通知中心收回侧贴到底走哪条入口，现有日志还不能定论，需要把拦截点再铺开。

## 本版改动

### 1. CoverSheet 状态探测补全

缓存 `SBCoverSheetPresentationManager` 实例，依次尝试四个 getter：

```
isCoverSheetPresented / coverSheetPresented / isPresented / presented
```

启动时把探测结果写进日志，方便确认类、实例、getter 是否存在：

```
coverSheet class=SBCoverSheetPresentationManager
coverSheet manager=SBCoverSheetPresentationManager
coverSheet getter isCoverSheetPresented responds=0 value=-1
coverSheet getter coverSheetPresented responds=0 value=-1
coverSheet getter isPresented responds=1 value=0
coverSheet getter presented responds=1 value=0
```

### 2. 扩充回收拦截点

| 方法 | 类 | 行为 |
|---|---|---|
| `sc_undockSession:animated:` | DockManager | CoverSheet 展示时跳过 |
| `sc_restoreAllDockedSessionsAnimated:` | DockManager | CoverSheet 展示时跳过 |
| `sc_closeSession:animated:` | SceneManager | CoverSheet 展示时跳过（v0.3.2 只记日志，本版拦截） |
| `sc_closeAllSessions` | SceneManager | CoverSheet 展示时跳过 |
| `sc_restoreRecordToNormalFrame:animated:completion:` | DockManager | 只记日志，不改行为 |

### 3. 下次需要回传的日志

安装后：

1. 重启 SpringBoard，看启动段 `coverSheet class/manager/getter` 四行；
2. 贴好侧贴，下拉一次通知中心，再收起；
3. 把整份 `ScreenCoreDock.log` 回传。

判断依据：

- `coverSheet manager=nil` -> 类名或 `sharedInstance` 不对，需要换状态来源；
- 四个 getter `responds=0` -> 这个类的属性名要再反查；
- 下拉后出现 `skip closeSession` / `skip closeAllSessions` -> 拦截生效；
- 四个入口都没出现新日志，但卡片还是消失 -> 走的是场景层隐藏（不在这五个方法里），再查 `sc_floatingDockManager:willDismissSession:` 或场景投递路径。

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 / v0.1.9 横屏可侧贴且不强制收回；
- v0.2.0~v0.2.3 横屏 1/4 缩放与左右/顶部间距；
- v0.3.0 移除四角监听与点角链路；
- v0.3.1 左区域改为关闭浮窗。
