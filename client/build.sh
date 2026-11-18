#!/bin/bash
# 重新编译并打包
set -e
cd "$(dirname "$0")"
APP="DJI 穿越摇杆 标定台.app"
swiftc -O -parse-as-library -o DJIClient DJIJoystickClient.swift \
  -framework SwiftUI -framework AppKit -framework IOKit -framework Combine -framework ApplicationServices
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp DJIClient "$APP/Contents/MacOS/DJIClient"
cp Info.plist "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
echo "built: $APP"
