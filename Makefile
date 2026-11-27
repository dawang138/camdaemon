# 阶段二 网络机位 · tweak dylib 注入 SpringBoard（rootless，THEOS）
# 在 GitHub Actions macOS runner 上编译；本机 Win 不参与编译。
# 路线 1：采集会话 + HTTP 服务跑在常驻系统进程 SpringBoard 内，绕开后台禁摄像头限制。

TARGET := iphone:clang:16.3
SDK := iPhoneOS16.5.sdk
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

# 部署目标对齐手机 iOS 16.3；minos 高于设备会被 dyld 拒绝加载。
TARGET_IPHONEOS_DEPLOYMENT_VERSION := 16.3

# ldid 签名注入摄像头 entitlement（越狱 AMFI 放宽，可自签注入）。
TARGET_CODESIGN_FLAGS := "-Sentitlements.plist"

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := CamDaemonSB

CamDaemonSB_FILES := \
	src/main.m \
	src/Config.m \
	src/FrameStore.m \
	src/CameraCapture.m \
	src/HttpServer.m \
	src/Logger.m

CamDaemonSB_CFLAGS := -fobjc-arc -std=c11 -Wall -Wno-deprecated-declarations -mios-version-min=16.3
CamDaemonSB_FRAMEWORKS := Foundation AVFoundation CoreGraphics CoreMedia CoreVideo UIKit

include $(THEOS)/makefiles/tweak.mk
