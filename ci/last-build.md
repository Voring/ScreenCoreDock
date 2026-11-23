# CI 构建报告

- workflow: `Build (roothide)`
- run: https://github.com/Voring/ScreenCoreDock/actions/runs/45247105787
- commit: `bb4ffb534376d138b2991042ba713b79d1364ecc`
- build result: **success**
- generated at: 2026-11-23T19:22:18Z

## build.log（末尾 500 行）

```log
stage: probe
runner-os: macOS / ARM64
Darwin sat12-dp146-a64b81fc-2228-47aa-aa65-c550852917b7-7277E4899D75.local 24.6.0 Darwin Kernel Version 24.6.0: Sun Oct 11 23:44:11 PDT 2026; root:xnu-11417.140.69.713.47~2/RELEASE_ARM64_VMAPPLE arm64
ProductName:		macOS
ProductVersion:		15.8.2
BuildVersion:		24H232
stage: diagnostics
Xcode 16.4
Build version 16F6
18.5
GNU Make 3.81
Copyright (C) 2006  Free Software Foundation, Inc.

This is perl 5, version 44, subversion 0 (v5.44.0) built for darwin-thread-multi-2level
stage: metadata
Package: com.voring.screencoredock
Name: ScreenCoreDock
Version: 0.4.3
Architecture: iphoneos-arm64
Depends: mobilesubstrate, com.susudear.screencore
stage: ldid
[32m==>[0m [1mDownloading bottle manifests[0m
✔︎ Bottle Manifest ldid (2.1.5_2)
[34m==>[0m [1mWould install 1 formula:[0m
ldid 2.1.5_2
[34m==>[0m [1mWould install 1 dependency for ldid:[0m
libplist 2.8.1
[32m==>[0m [1mFetching downloads for: [32mldid[39m[0m
✔︎ Bottle Manifest libplist (2.8.1)
✔︎ Bottle ldid (2.1.5_2)
✔︎ Bottle libplist (2.8.1)
[32m==>[0m [1mInstalling ldid dependency: [32mlibplist[39m (2.8.1)[0m
[34m==>[0m [1mPouring libplist--2.8.1.arm64_sequoia.bottle.tar.gz[0m
🍺  /opt/homebrew/Cellar/libplist/2.8.1: 33 files, 662.3KB
[32m==>[0m [1mInstalling [32mldid[39m[0m
[34m==>[0m [1mPouring ldid--2.1.5_2.arm64_sequoia.bottle.tar.gz[0m
🍺  /opt/homebrew/Cellar/ldid/2.1.5_2: 6 files, 274.7KB
/opt/homebrew/bin/ldid
usage: ldid -S[entitlements.xml] <binary>
   ldid -e MobileSafari
   ldid -S cat
   ldid -Stfp.xml gdb
ldid unavailable
stage: theos-setup
Cloning into '/Users/runner/work/_temp/theos'...
Submodule 'vendor/dm.pl' (https://github.com/theos/dm.pl.git) registered for path 'vendor/dm.pl'
Submodule 'vendor/include' (https://github.com/roothide/headers.git) registered for path 'vendor/include'
Submodule 'vendor/lib' (https://github.com/roothide/lib.git) registered for path 'vendor/lib'
Submodule 'vendor/logos' (https://github.com/theos/logos.git) registered for path 'vendor/logos'
Submodule 'vendor/nic' (https://github.com/theos/nic.git) registered for path 'vendor/nic'
Submodule 'vendor/orion' (https://github.com/theos/orion.git) registered for path 'vendor/orion'
Submodule 'vendor/swift-support' (https://github.com/theos/swift-support.git) registered for path 'vendor/swift-support'
Submodule 'vendor/templates' (https://github.com/theos/templates.git) registered for path 'vendor/templates'
Cloning into '/Users/runner/work/_temp/theos/vendor/dm.pl'...
Cloning into '/Users/runner/work/_temp/theos/vendor/include'...
Cloning into '/Users/runner/work/_temp/theos/vendor/lib'...
Cloning into '/Users/runner/work/_temp/theos/vendor/logos'...
Cloning into '/Users/runner/work/_temp/theos/vendor/nic'...
Cloning into '/Users/runner/work/_temp/theos/vendor/orion'...
Cloning into '/Users/runner/work/_temp/theos/vendor/swift-support'...
Cloning into '/Users/runner/work/_temp/theos/vendor/templates'...
Submodule path 'vendor/dm.pl': checked out 'd9a3b72e274226dd2823c0a7c1d6d05099f4f51c'
Submodule path 'vendor/include': checked out 'e1132e2bbc3ca15c50e2311bcd349cb7353409e1'
Submodule path 'vendor/lib': checked out '85e9b5b8aff11bbefc59525c64c8f55149926e56'
Submodule path 'vendor/logos': checked out '365a4e7028234e90bc2cbc724e5c87607130d3b3'
Submodule path 'vendor/nic': checked out '4e7adcbeac2e4636b91e2f76341adfe4c4d0ceec'
Submodule path 'vendor/orion': checked out '762159dc214d5aafa2edfc7554c659fc3c658b5b'
Submodule 'fishhook' (https://github.com/facebook/fishhook.git) registered for path 'vendor/orion/fishhook'
Cloning into '/Users/runner/work/_temp/theos/vendor/orion/fishhook'...
Submodule path 'vendor/orion/fishhook': checked out 'aadc161ac3b80db07a9908851839a17ba63a9eb1'
Submodule path 'vendor/swift-support': checked out '4cf59ff04cdb2ceb27ea2228753e0497297b6182'
Submodule path 'vendor/templates': checked out '6c3944e281c4726f1383755d0fbb642840312d28'
Cloning into '/tmp/sdks'...
SDK_DIR=iPhoneOS16.5.sdk
total 0
drwxr-xr-x   4 runner  staff  128 Nov 23 19:21 .
drwxr-xr-x  22 runner  staff  704 Nov 23 19:21 ..
-rw-r--r--   1 runner  staff    0 Nov 23 19:21 .keep
drwxr-xr-x   8 runner  staff  256 Nov 23 19:21 iPhoneOS16.5.sdk
stage: make-package
THEOS=/Users/runner/work/_temp/theos
[0;36m==> [1;39mCleaning…[m
[0;36m==> [1;36mNotice:[m Build may be slow as Theos isn’t using all available CPU cores on this computer. Consider upgrading GNU Make: https://theos.dev/docs/parallel-building
[1;31m> [1;3;39mMaking all for tweak ScreenCoreDock…[m
[0;31m==> [1;39mPreprocessing Tweak.xm…[m
[0;32m==> [1;39mCompiling Tweak.xm (arm64)…[m
[0;33m==> [1;39mLinking tweak ScreenCoreDock (arm64)…[m
ld: warning: -multiply_defined is obsolete
[0;34m==> [1;39mGenerating debug symbols for ScreenCoreDock…[m
[0;34m==> [1;39mStripping ScreenCoreDock (arm64)…[m
[0;31m==> [1;39mPreprocessing Tweak.xm…[m
[0;32m==> [1;39mCompiling Tweak.xm (arm64e)…[m
[0;33m==> [1;39mLinking tweak ScreenCoreDock (arm64e)…[m
ld: warning: -multiply_defined is obsolete
[0;34m==> [1;39mGenerating debug symbols for ScreenCoreDock…[m
[0;34m==> [1;39mStripping ScreenCoreDock (arm64e)…[m
[0;34m==> [1;39mMerging tweak ScreenCoreDock…[m
[0;34m==> [1;39mSigning ScreenCoreDock…[m
[1;31m> [1;3;39mMaking stage for tweak ScreenCoreDock…[m
dm.pl: building package `com.voring.screencoredock:iphoneos-arm64e' in `./packages/com.voring.screencoredock_0.4.3_iphoneos-arm64e.deb'
total 32
-rw-r--r--  1 runner  staff    12K Nov 23 19:22 com.voring.screencoredock_0.4.3_iphoneos-arm64e.deb
```
