# ScreenCoreDock v0.2.6

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.2.6`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 日志说了什么

v0.2.5 的真机日志（`/var/mobile/Library/Logs/ScreenCoreDock.log`）：

```
v0.2.5 loaded in SpringBoard
hooked sc_handleDockTap: on SCFloatingContainerView
hooked (open + dockSession + orientation + restoreAllDocked + targetFrames + dockTap)
landscape entry: keep docked records (skip restoreAllDockedSessionsAnimated:)
landscape frames side=1 scale=0.50 {{674, 0}, {170, 301.93}} -> {{674, 36.75}, {85, 150.97}}
landscape relayout done
```

hook 全部挂上、转入横屏不丢侧贴、缩放重排也都正常。**但点四角那 12 秒里，一行 `landscape dock tap` 都没有**。

结论：点击根本没有到达 `sc_handleDockTap:`，问题在**手势层**（横屏下四角 region 没被命中），不在 dock 层。前面几版一直在 dock 层加兜底，方向错了。

## 本版改法

不再依赖插件自己那套四角 region。横屏时（以及浮窗刚建出来时）遍历 `hostRootView`，给每个 `SCFloatingContainerView` 自建一个 `UITapGestureRecognizer`：

```objc
UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:proxy action:@selector(sc_cornerTap:)];
tap.numberOfTapsRequired = 1;
tap.cancelsTouchesInView = NO;   // 不吞掉拖动/原手势
tap.delaysTouchesEnded = NO;
[view addGestureRecognizer:tap];
```

点击时按落点算角：

```
zone = min(width, height, 48)
左上 -> 1，右上 -> 2，左下 -> 3，右下 -> 4
```

然后走统一的 `sc_dockContainerFromCorner:`：先是原来的 delegate 转发，不行就 `sc_sessionForContainerView:`，再不行退 `activeSession`，最后调 `sc_dockSession:fromCorner:`（横屏会顶成竖屏重入，仍失败再走 DockManager 层）。

tap 需要「按下抬起几乎不动」才会识别，所以拖动结束不会误触。

另外加了一路诊断：hook `sc_layoutExternalInteractionRegions`，把四角 region 的 frame / tag / 命中开关写进日志，确认它们在横屏下到底被摆到哪。

## 日志里会多出

```
installed own corner tap on SCFloatingContainerView bounds={{674, 36.75}, {85, 151}}
regions layout: container={{0, 0}, {85, 151}} [tag=1 {{?,?},{?,?}} hit=1] ...
own corner tap at 6,9 in 85x151 -> corner=1
own corner dock corner=1 delegate=SCFloatingSceneManager
own corner dock ok via forward
own corner dock direct dock corner=1 ok=1
```

- 有 `own corner tap` 但 `corner=0` -> 点的位置不在角落区（zone 太小或容器 bounds 变大）
- 有 `corner` 但 `direct dock ok=0` -> 到了 dock 层被拒，按 session 类型继续拆
- 压根没有 `own corner tap` -> 手势没被装上或没命中，看 `installed own corner tap on ...` 那行是否出现

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 放开 `sc_dockSession:fromCorner:` 横屏方向守卫；
- v0.1.9 转入横屏不强制收回侧贴；
- v0.2.0 横屏卡片 0.5 缩放 + 紧凑重排（`LandscapeDockScale`）；
- v0.2.1 横屏左右间距对齐；
- v0.2.2 修安全模式；
- v0.2.3 顶部间距缩到 1/4；
- v0.2.4 点角 session 兜底改走 activeSession；
- v0.2.5 日志落盘。
