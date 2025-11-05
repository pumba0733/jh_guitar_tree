#!/bin/bash
set -e
cd "$(dirname "$0")/macos/frameworks"

echo "🎸 [1/5] Building SoundTouch FFI (Debug, universal)..."

# --- arm64 ---
clang++ -std=c++17 -arch arm64 -dynamiclib soundtouch_ffi_bridge.cpp \
  -I../ThirdParty/soundtouch/include \
  -L../ThirdParty/soundtouch/build_arm64 \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_arm64.dylib

# --- x86_64 ---
clang++ -std=c++17 -arch x86_64 -dynamiclib soundtouch_ffi_bridge.cpp \
  -I../ThirdParty/soundtouch/include \
  -L../ThirdParty/soundtouch/build_x86_64 \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_x86_64.dylib

# --- universal merge ---
lipo -create -output libsoundtouch_ffi_universal.dylib \
  libsoundtouch_ffi_arm64.dylib libsoundtouch_ffi_x86_64.dylib

# --- copy & sign (Debug) ---
APP_DEBUG="../../build/macos/Build/Products/Debug/guitartree.app/Contents/Frameworks"
mkdir -p "$APP_DEBUG"

echo "📦 Copying to $APP_DEBUG"
cp -f libsoundtouch_ffi_universal.dylib "$APP_DEBUG/libsoundtouch_ffi.dylib"
chmod +x "$APP_DEBUG/libsoundtouch_ffi.dylib"

echo "🔏 Codesigning..."
codesign --force --deep --sign - "$APP_DEBUG/libsoundtouch_ffi.dylib"

echo "✅ Debug build complete."
