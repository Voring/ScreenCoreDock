TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# 打包方案（按你的环境二选一，取消注释）
# export THEOS_PACKAGE_SCHEME = roothide
# export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenCoreDock
ScreenCoreDock_FILES = Tweak.xm
ScreenCoreDock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
