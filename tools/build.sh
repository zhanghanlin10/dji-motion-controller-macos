#!/bin/bash
# 编译所有诊断工具（需要 Xcode Command Line Tools）
set -e
cd "$(dirname "$0")"

IOKIT="-framework IOKit -framework CoreFoundation"
clang -O2 -o hid_dump     hid_dump.c     $IOKIT
clang -O2 -o hid_watch2   hid_watch2.c   $IOKIT
clang -O2 -o dji_hud      dji_hud.c      $IOKIT

SDL=$(brew --prefix sdl2 2>/dev/null || echo /opt/homebrew)
if [ -d "$SDL/include" ]; then
  clang -O2 -o sdl_probe     sdl_probe.c     -I"$SDL/include/SDL2" -L"$SDL/lib" -lSDL2
  clang -O2 -o sdl_map_test  sdl_map_test.c  -I"$SDL/include/SDL2" -L"$SDL/lib" -lSDL2
else
  echo "跳过 SDL 工具（未找到 SDL2：brew install sdl2）"
fi
echo "构建完成"
