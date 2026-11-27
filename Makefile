# 阶段二 网络机位 daemon · rootless 编译（THEOS，application bundle 形态）
# 在 GitHub Actions macOS runner 上执行；本机 Win 不参与编译。
# 改造点：由裸 tool 改为 .app bundle，使 TCC 能按 bundle ID 识别授权身份。

TARGET := iphone:clang:16.5
SDK := iPhoneOS16.5.sdk
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

# ldid 签名时注入摄像头 entitlement（越狱设备 AMFI 放宽，可自签注入）。
TARGET_CODESIGN_FLAGS := "-Sentitlements.plist"

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := CamDaemon

CamDaemon_FILES := \
	src/main.m \
	src/Config.m \
	src/FrameStore.m \
	src/CameraCapture.m \
	src/HttpServer.m

CamDaemon_CFLAGS := -fobjc-arc -std=c11 -Wall -Wno-deprecated-declarations
CamDaemon_FRAMEWORKS := Foundation AVFoundation CoreGraphics CoreMedia CoreVideo UIKit
CamDaemon_RESOURCE_FILES := Info.plist

include $(THEOS)/makefiles/application.mk
