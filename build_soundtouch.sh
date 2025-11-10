#!/bin/bash
set -e
cd "$(dirname "$0")/macos/frameworks"

echo "🎸 [1/5] Building SoundTouch + miniaudio FFI (Debug, universal)..."

SRC1="soundtouch_ffi_bridge.cpp"
SRC2="audio_chain_miniaudio.cpp"
INCLUDE_SOUNDTOUCH="../ThirdParty/soundtouch/include"
INCLUDE_MINIAUDIO="../ThirdParty/miniaudio/include"
LIB_ARM64="../ThirdParty/soundtouch/build_arm64"
LIB_X86="../ThirdParty/soundtouch/build_x86_64"

# --- arm64 ---
echo "🧱 [2/5] arm64 build..."
clang++ -std=c++17 -arch arm64 -dynamiclib "$SRC1" "$SRC2" \
  -I"$INCLUDE_SOUNDTOUCH" -I"$INCLUDE_MINIAUDIO" \
  -L"$LIB_ARM64" \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_arm64.dylib

# --- x86_64 ---
echo "🧱 [3/5] x86_64 build..."
clang++ -std=c++17 -arch x86_64 -dynamiclib "$SRC1" "$SRC2" \
  -I"$INCLUDE_SOUNDTOUCH" -I"$INCLUDE_MINIAUDIO" \
  -L"$LIB_X86" \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_x86_64.dylib

# --- universal merge ---
echo "🔗 [4/5] Merging universal binary..."
lipo -create -output libsoundtouch_ffi_universal.dylib \
  libsoundtouch_ffi_arm64.dylib libsoundtouch_ffi_x86_64.dylib

# --- copy & sign ---
APP_DEBUG="../../build/macos/Build/Products/Debug/guitartree.app/Contents/Frameworks"
mkdir -p "$APP_DEBUG"
cp -f libsoundtouch_ffi_universal.dylib "$APP_DEBUG/libsoundtouch_ffi.dylib"
chmod +x "$APP_DEBUG/libsoundtouch_ffi.dylib"
codesign --force --deep --sign - "$APP_DEBUG/libsoundtouch_ffi.dylib"

echo "✅ [5/5] Build complete!"
