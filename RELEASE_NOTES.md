# ScreenCoreDock v0.2.2

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.2.2`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

逻辑仍是 **v0.1.0 基线**（打开分屏 -> 补一次 dock），叠加横屏的四项放开与几何修正。本版只修一个致命问题：**装上即安全模式**。

### 安全模式 / SpringBoard 崩溃（本版 v0.2.2 修）

崩溃日志 `SpringBoard-2026-11-15-155516.ips`：

- `bug_type 309`、`EXC_BREAKPOINT` / `SIGTRAP`，崩溃线程为 0（主线程）；
- 栈底 `dyld4::Loader::findAndRunAllInitializers` -> `injection_init` -> `initializer`，说明崩在 dylib 初始化器里；
- 第 42 号镜像 `.../usr/lib/TweakInject/ScreenCoreDock.dylib`（base `0x101c64000`），两帧 `imageOffset 16416 (0x4020)` 与 `16948 (0x4234)`；
- 其上为 CoreFoundation 的 `_CF_forwarding_prep_0` / `___forwarding___`，即向某个对象发了它不认识的选择器。

对照 arm64e 切片反汇编：

```
0x4020  %ctor 返回点（0x4000 -> bl 0x4040 installHook）
0x4224  ldr  x24,[x26]        ; 取类表里的一个类
0x422c  mov  x2,x20           ; x20 = selref __DATA_CONST 0xc100
0x4230  bl   0x5cc0           ; objc_msgSend
0x4234  cbz  w0,...           ; 崩溃点
```

即崩在「遍历 `objc_getClassList` 结果、逐个 `[c instancesRespondToSelector:]`」这一步。

**根因**：这段扫描写在 dylib 的初始化器（`%ctor`）里。此时 dyld 还在跑其它库的初始化，类表里存在尚未 realize 的类，对它们发消息会走 forwarding，直接 SIGTRAP 把 SpringBoard 带走（安全模式）。

**修法**：不再遍历全类表，直接按类名取：

```objc
Class containerCls = objc_getClass("SCFloatingContainerView");
if (containerCls && [containerCls instancesRespondToSelector:@selector(sc_handleDockTap:)]) {
    MSHookMessageEx(containerCls, @selector(sc_handleDockTap:), (IMP)hook_handleDockTap, (IMP *)&orig_handleDockTap);
}
```

类名来源（二进制确认，不是猜的）：`__objc_classlist` -> `class_ro_t` 名字表里，方法列表含 `sc_handleDockTap:`、`isDocked`、`delegate` 的那个类就是 `SCFloatingContainerView`（即 `work/meths2.json` 中 `0x72f08` 那条）。挂不上时只打日志跳过，绝不再扫描。

另外给 `orig_handleDockTap` 加了空指针保护。

### 之前的改动照旧保留

- **v0.1.8** `-sc_dockSession:fromCorner:`（0x463ac）方向守卫（0x463e4 只接受 1/2）已放开；
- **v0.1.9** 转入横屏时 `-sc_restoreAllDockedSessionsAnimated:`（0x42ca8 尾部 0x42ee0）不再强制收回；
- **v0.2.0** 横屏卡片按 `LandscapeDockScale`（默认 0.5，面积 1/4）缩放并紧凑重排；
- **v0.2.1** 横屏点四角转发 `sc_floatingContainerView:didRequestDockFromCorner:`；横屏左右间距统一为 `8 + 旧宽 × (1 - scale)`，顶部为 `该值 + 状态栏高度`。

## 真机验证

```sh
log stream --predicate 'eventMessage CONTAINS "ScreenCoreDock"'
```

装上后应先看到：

```
[ScreenCoreDock] hooked sc_handleDockTap: on SCFloatingContainerView
[ScreenCoreDock] hooked (open + dockSession + orientation + restoreAllDocked + targetFrames + dockTap)
```

不应再出现安全模式；若 `SCFloatingContainerView not found, dock tap hook skipped`，说明类名不匹配，把该行发我。

## 逆向备忘（arm64，未滑动地址）

| 地址 | 选择器 / 函数 |
|---|---|
| `0x48eb8` | `-sc_openFrontmostApplicationAsSplitFromSourceRect:` |
| `0x463ac` | `-sc_dockSession:fromCorner:`（方向守卫 0x463e4） |
| `0x3bde4` | `SCFloatingDockManager -sc_dockSession:fromCorner:` |
| `0x42ca8` | `-sc_activeHostOrientationDidChange:duration:`（横屏收回 0x42ee0） |
| `0x3d13c` | `-sc_restoreAllDockedSessionsAnimated:` |
| `0x3a384` | `-sc_targetFramesForSide:`（宽度 0.23×hostW / 高度按 normalFrame 比例） |
| `0x3b1fc` | `-sc_layoutSide:animated:completion:` |
| `0x3fb28` | `-hostOrientation` |
| `0x386b0` | `-sc_handleDockTap:`（横屏 0x38738 宽>高直接 return） |
| `0x4931c` | `-sc_floatingContainerView:didRequestDockFromCorner:` |
| `0x33c98` | `_SCFloatingPortraitTopInset`（横屏返回 0） |
