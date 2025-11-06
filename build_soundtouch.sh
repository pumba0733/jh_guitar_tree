#!/bin/bash
set -e
cd "$(dirname "$0")/macos/frameworks"

echo "🎸 [1/5] Building SoundTouch FFI (Debug, universal)..."

SRC="soundtouch_ffi_bridge.cpp"
INCLUDE_DIR="../ThirdParty/soundtouch/include"
INCLUDE_DIR2="../ThirdParty/soundtouch/include/soundtouch"

# --- arm64 ---
echo "🧱 [2/5] arm64 build..."
clang++ -std=c++17 -arch arm64 -dynamiclib "$SRC" \
  -I"$INCLUDE_DIR" -I"$INCLUDE_DIR2" \
  -L"../ThirdParty/soundtouch/build_arm64" \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_arm64.dylib

# --- x86_64 ---
echo "🧱 [3/5] x86_64 build..."
clang++ -std=c++17 -arch x86_64 -dynamiclib "$SRC" \
  -I"$INCLUDE_DIR" -I"$INCLUDE_DIR2" \
  -L"../ThirdParty/soundtouch/build_x86_64" \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_x86_64.dylib

# --- universal merge ---
echo "🔗 [4/5] Merging into universal binary..."
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

echo "✅ [5/5] Debug universal build complete!"
