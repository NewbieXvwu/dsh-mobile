#!/bin/sh
set -eu

# Android Studio 强制 XcodeDefault 时会屏蔽独立安装的 Metal 工具链。
# 只在着色器编译子进程取消该覆盖，不改动 Swift/Kotlin 工具链。
metal_sdk="$SDKROOT"
unset TOOLCHAINS SDKROOT
if [ "$PLATFORM_NAME" = "macosx" ]; then
  # Mac Catalyst：Metal 按 macOS 运行时目标编译（Catalyst 16.1 ↔ macOS 12.3）。
  metal_target="air64-apple-macos12.3"
else
  metal_target="air64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}"
  if [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
    metal_target="${metal_target}-simulator"
  fi
fi
output_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DERIVED_FILE_DIR" "$output_directory"
metal_executable="$(/usr/bin/xcrun --find metal)"
metal_tools="$(dirname "$metal_executable")"
"$metal_executable" \
  -c "$SRCROOT/DeepSeekHarnessMobile/Shaders/HarnessBackground.metal" \
  -target "$metal_target" -isysroot "$metal_sdk" \
  -fmodules-cache-path="$DERIVED_FILE_DIR/MetalModuleCache" \
  -o "$DERIVED_FILE_DIR/HarnessBackground.air"
"$metal_tools/metallib" \
  "$DERIVED_FILE_DIR/HarnessBackground.air" \
  -o "$output_directory/default.metallib"
