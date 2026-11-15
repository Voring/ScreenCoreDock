# ScreenCoreDock v0.3.1

## 版本号

- 包名：`com.voring.screencoredock`
- 版本：`0.3.1`
- 依赖：`mobilesubstrate, com.susudear.screencore`
- 架构：`iphoneos-arm64`（编译 arm64 + arm64e）
- 打包方案：`roothide`

## 改动说明

把浮窗左侧手势区从「转全屏」改为「关闭浮窗」，与右侧/下侧一致。

### 逆向依据

`-[SCFloatingContainerView sc_installExternalInteractionRegions]`（0x34628）按 identifier 建四个边缘手势区：

```
0x34665c  CFSTR "ScreenCore.Split.TopMoveFullscreen"
0x346674  CFSTR "ScreenCore.Split.LeftMoveFullscreen"
0x3466c0  CFSTR "ScreenCore.Split.BottomMoveClose"
0x3466dc  CFSTR "ScreenCore.Split.RightMoveClose"

0x346690  ldr x21,[0xab090]   ; sc_handleFullscreenTap:
0x3466a8  bl  sc_addMoveAndTapGesturesToRegion:tapAction:   ; Top    -> fullscreen
0x3466b8  bl  sc_addMoveAndTapGesturesToRegion:tapAction:   ; Left   -> fullscreen

0x3466f8  ldr x24,[0xab098]   ; sc_handleCloseTap:
0x34670c  bl  sc_addMoveAndTapGesturesToRegion:tapAction:   ; Bottom -> close
0x34672c  bl  sc_addMoveAndTapGesturesToRegion:tapAction:   ; Right  -> close
```

selref 解析：`0xab090 -> "sc_handleFullscreenTap:"`，`0xab098 -> "sc_handleCloseTap:"`。

并且 `sc_interactionRegionWithIdentifier:`（0x342e0）建区域时会 `setAccessibilityIdentifier:`，所以区域视图自带 identifier，可直接辨认。

### 本版改法

hook `sc_handleFullscreenTap:`，看被点区域的 `accessibilityIdentifier`：

```objc
if ([ident isEqualToString:@"ScreenCore.Split.LeftMoveFullscreen"]) {
    [self sc_handleCloseTap:gesture];
    return;
}
```

其余（顶部区域）原样放行，仍为全屏。

### 改动后的行为

| 手势区 | 行为 |
|---|---|
| Top | 全屏（不变） |
| Left | **关闭浮窗**（本版改变） |
| Bottom | 关闭浮窗（不变） |
| Right | 关闭浮窗（不变） |

### 日志

```
v0.3.1 loaded in SpringBoard
hooked sc_handleFullscreenTap: (left region -> close)
hooked (open + dockSession + orientation + restoreAllDocked + targetFrames + leftRegionClose)
left gesture region tapped, close floating window instead of fullscreen
```

## 保留的既有改动

- v0.1.0 基线：打开分屏后补一次 dock；
- v0.1.8 横屏可侧贴；
- v0.1.9 转横屏不强制收回侧贴；
- v0.2.0 横屏卡片 1/4 缩放 + 紧凑重排；
- v0.2.1 横屏左右间距对齐；
- v0.2.3 横屏顶部间距 1/4；
- v0.3.0 移除四角监听与点角链路。
