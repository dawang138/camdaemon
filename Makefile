# 阶段二 网络机位 daemon · rootless 编译（THEOS）
# 在 GitHub Actions macOS runner 上执行；本机 Win 不参与编译。

TARGET := iphone:clang:16.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME := camdaemon

camdaemon_FILES := \
	src/main.m \
	src/Config.m \
	src/FrameStore.m \
	src/CameraCapture.m \
	src/HttpServer.m

camdaemon_CFLAGS := -fobjc-arc -std=c11 -Wall -Wno-deprecated-declarations
camdaemon_FRAMEWORKS := Foundation AVFoundation CoreGraphics CoreMedia CoreVideo

include $(THEOS)/makefiles/tool.mk
