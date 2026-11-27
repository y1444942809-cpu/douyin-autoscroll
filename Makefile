# Theos 可选构建方式（Mac + Theos 用户）
TARGET = iphone:clang:latest:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DouyinAutoScroll
DouyinAutoScroll_FILES = DouyinAutoScroll.m
DouyinAutoScroll_CFLAGS = -fobjc-arc -w
DouyinAutoScroll_FRAMEWORKS = AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
