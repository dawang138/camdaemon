# 阶段二 网络机位 · tweak dylib 注入 SpringBoard（rootless，THEOS）
# 在 GitHub Actions macOS runner 上编译；本机 Win 不参与编译。
# 路线 1：采集会话 + HTTP 服务跑在常驻系统进程 SpringBoard 内，绕开后台禁摄像头限制。

TARGET := iphone:clang:16.5
SDK := iPhoneOS16.5.sdk
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

# ldid 签名注入摄像头 entitlement（越狱 AMFI 放宽，可自签注入）。
TARGET_CODESIGN_FLAGS := "-Sentitlements.plist"

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := CamDaemonSB

CamDaemonSB_FILES := \
	src/main.m \
	src/Config.m \
	src/FrameStore.m \
	src/CameraCapture.m \
	src/HttpServer.m

CamDaemonSB_CFLAGS := -fobjc-arc -std=c11 -Wall -Wno-deprecated-declarations
CamDaemonSB_FRAMEWORKS := Foundation AVFoundation CoreGraphics CoreMedia CoreVideo UIKit

include $(THEOS)/makefiles/tweak.mk
