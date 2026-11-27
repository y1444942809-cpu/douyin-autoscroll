#!/bin/bash
# 在 Mac 上本地编译（需要 Xcode Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "使用 SDK: $SDK"

clang -target arm64-apple-ios15.0 \
  -isysroot "$SDK" \
  -fobjc-arc \
  -fobjc-runtime=ios-15.0 \
  -fPIC \
  -dynamiclib \
  -framework Foundation \
  -framework UIKit \
  -framework AVFoundation \
  -framework QuartzCore \
  -o DouyinAutoScroll.dylib \
  DouyinAutoScroll.m

codesign -s - --force DouyinAutoScroll.dylib
file DouyinAutoScroll.dylib
echo "构建完成: $(pwd)/DouyinAutoScroll.dylib"
