# ScreenCoreDock v0.2.5

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.2.5`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

本版不改逻辑，只把日志落盘，方便直接取证。

### 日志文件在哪

每次 `SC_LOG` 除了 `NSLog`，还会追加写入：

```
/var/mobile/Library/Logs/ScreenCoreDock.log
```

这个目录不可写时自动退回：

```
/tmp/ScreenCoreDock.log
```

文件是纯文本，一行一条，带时间戳。

### 取日志的三种方式

1. **Filza**（最省事）：打开 Filza，进 `/var/mobile/Library/Logs/`，找到 `ScreenCoreDock.log`，右上角分享/复制内容即可。若那里没有，就去 `/tmp/` 找。
2. **SSH / NewTerm 2**（root）：

```sh
cat /var/mobile/Library/Logs/ScreenCoreDock.log | tail -50
```

3. **Mac / PC 上跑 Xcode 的 devices 日志**：

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

### 本版开头会先写一行启动标记

```
v0.2.5 loaded in SpringBoard
hooked sc_handleDockTap: on SCFloatingContainerView
hooked (open + dockSession + orientation + restoreAllDocked + targetFrames + dockTap)
```

只要文件里有这三行，说明插件本身已经加载并挂上了 hook；接下来点一次横屏角落，会出现：

```
landscape dock tap enter, superview={{0, 0}, {852, 393}}
landscape dock tap corner=N delegate=SCFloatingSceneManager
landscape dock tap ok via forward
landscape dock tap direct dock corner=N ok=1
landscape dock tap: no session at all
```

### 怎么判断问题出在哪一层

- **一行 `landscape dock tap` 都没有** -> 点击根本没到 `sc_handleDockTap:`，问题在横屏下四角 region 的布局/命中，不在 dock 层；
- **有 `enter` 但 `corner=0`** -> 命中视图的 tag 不是 1..4，手势区域没按预期设置；
- **有 `enter`、有 `corner`，但 `ok=0` / `no session at all`** -> dock 层被拒，按日志里的 session 类型继续拆。

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 放开 `sc_dockSession:fromCorner:` 横屏方向守卫；
- v0.1.9 转入横屏不强制收回侧贴；
- v0.2.0 横屏卡片 0.5 缩放 + 紧凑重排（`LandscapeDockScale`）；
- v0.2.1 横屏左右间距对齐；
- v0.2.2 修安全模式；
- v0.2.3 顶部间距缩到 1/4；
- v0.2.4 点角 session 兜底改走 activeSession。
