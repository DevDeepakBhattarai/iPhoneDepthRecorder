TARGET_CODESIGN = /usr/bin/true
TARGET_CODESIGN_FLAGS =
TARGET := iphone:clang:16.5:15.4
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DepthRecorder
DepthRecorder_FILES = main.m AppDelegate.m RecorderViewController.m RecorderSettingsViewController.m CaptureEngine.m RecordingSession.m PreviewRenderer.m RemoteControlServer.m
DepthRecorder_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreGraphics AudioToolbox CoreImage Metal MetalKit QuartzCore
DepthRecorder_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
DepthRecorder_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
