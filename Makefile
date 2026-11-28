# 阶段二 网络机位 · tweak dylib 注入 SpringBoard（rootless，THEOS）
# 在 GitHub Actions macOS runner 上编译；本机 Win 不参与编译。
# 路线 1：采集会话 + HTTP 服务跑在常驻系统进程 SpringBoard 内，绕开后台禁摄像头限制。

TARGET := iphone:clang:15.6:15.0
SDK := iPhoneOS15.6.sdk
# SB 等系统进程以 arm64e ABI 运行，必须同时出 arm64 与 arm64e 两个 slice（fat dylib），
# 否则 arm64e 进程 dlopen 报 "incompatible architecture (have arm64, need arm64e)"。
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

# 部署目标对齐手机 iOS 16.3：THEOS TARGET 第三段决定 SDK 与 -target 版本，
# SDK 清单无 16.3，故选存在的 15.6 SDK（minos 15.6 ≤ 16.3）。

# ldid 签名注入摄像头 entitlement（越狱 AMFI 放宽，可自签注入）。
TARGET_CODESIGN_FLAGS := "-Sentitlements.plist"

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := CamDaemonSB MediaPatch

CamDaemonSB_FILES := \
	src/main.m \
	src/Config.m \
	src/FrameStore.m \
	src/AudioStore.m \
	src/CameraCapture.m \
	src/HttpServer.m \
	src/Logger.m

CamDaemonSB_CFLAGS := -fobjc-arc -std=c11 -Wall -Wno-deprecated-declarations
CamDaemonSB_FRAMEWORKS := Foundation AVFoundation CoreGraphics CoreMedia CoreVideo UIKit AudioToolbox

# 路线 B：注入 mediaserverd，hook hasBackgroundCameraAccess 恒 YES，解除后台摄像头吊销。
MediaPatch_FILES := src/MediaPatch.m
MediaPatch_CFLAGS := -fobjc-arc -std=c11 -Wall -Wno-deprecated-declarations

include $(THEOS)/makefiles/tweak.mk
