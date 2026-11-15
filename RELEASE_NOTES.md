# ScreenCoreDock v0.3.4

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.4`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 崩溃原因

v0.3.3 装上后进安全模式，真机 ips（`SpringBoard-2026-11-15-191559.ips`）崩溃栈：

```
+[SBCoverSheetPresentationManager sharedInstance]
  __49+[SBCoverSheetPresentationManager sharedInstance]_block_invoke
-[SBCoverSheetPresentationManager init]
-[SBCoverSheetPresentationManager _newRubberBandFeedbackGeneratorForSettings:]
std::terminate() / abort()  SIGABRT
```

我们在启动 hook 阶段（`%ctor` 后立刻）就调了 `sharedInstance`。这个单例的 `init` 里要建震动反馈生成器，启动早期环境未就绪，直接 `abort()`；`@try/@catch` 拦不住 SIGABRT。

## 本版修复

- 启动时只 `objc_getClass` 看类是否存在，**不碰 `sharedInstance`**；
- `sharedInstance` 延迟 5 秒后才在主队列懒加载，之后 hook 触发时才查询 CoverSheet 状态；
- 其它回收拦截点（undock / restoreAll / closeSession / closeAll / restoreRecord 日志）保留。

## 启动后日志预期

```
v0.3.4 loaded in SpringBoard
hooked sc_undockSession:animated: ...
coverSheet class=SBCoverSheetPresentationManager
...（5 秒后）
coverSheet manager=...
coverSheet getter isCoverSheetPresented responds=...
coverSheet getter coverSheetPresented responds=...
coverSheet getter isPresented responds=...
coverSheet getter presented responds=...
```

若 `coverSheet manager=nil` 或四个 getter 全 `responds=0`，把这段日志回传，再换状态来源。

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 / v0.1.9 横屏可侧贴且不强制收回；
- v0.2.0~v0.2.3 横屏 1/4 缩放与左右/顶部间距；
- v0.3.0 移除四角监听与点角链路；
- v0.3.1 左区域改为关闭浮窗。
