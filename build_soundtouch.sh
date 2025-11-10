#!/bin/bash
set -e

# 🎧 SmartMediaPlayer FFI Builder (miniaudio + SoundTouch)
# macOS Universal (arm64 + x86_64)
# Usage: ./build_soundtouch.sh [release]
# Default = debug

MODE="${1:-debug}"
MODE_UPPER=$(echo "$MODE" | tr '[:lower:]' '[:upper:]')

cd "$(dirname "$0")/macos/frameworks"
echo "🎸 [1/4] Building SoundTouch + miniaudio FFI ($MODE_UPPER, universal)..."

SRC="audio_chain_miniaudio.cpp"
INCLUDE_SOUNDTOUCH="../ThirdParty/soundtouch/include"
INCLUDE_MINIAUDIO="../ThirdParty/miniaudio/include"
LIB_ARM64="../ThirdParty/soundtouch/build_arm64"
LIB_X86="../ThirdParty/soundtouch/build_x86_64"
OUT_ARM64="libsoundtouch_ffi_arm64.dylib"
OUT_X86="libsoundtouch_ffi_x86_64.dylib"
OUT_UNI="libsoundtouch_ffi_universal.dylib"

COMMON_FLAGS="-std=c++17 -dynamiclib -framework AudioToolbox -framework CoreAudio"
INCLUDE_FLAGS="-I$INCLUDE_SOUNDTOUCH -I$INCLUDE_MINIAUDIO"

if [[ "$MODE" == "release" ]]; then
  OPT_FLAGS="-O3 -DNDEBUG"
  APP_DIR="../../build/macos/Build/Products/Release/guitartree.app/Contents/Frameworks"
else
  OPT_FLAGS="-g"
  APP_DIR="../../build/macos/Build/Products/Debug/guitartree.app/Contents/Frameworks"
fi

# --- arm64 ---
echo "🧱 [1/4] arm64 build..."
clang++ $COMMON_FLAGS -arch arm64 $OPT_FLAGS "$SRC" $INCLUDE_FLAGS -L"$LIB_ARM64" -lsoundtouch -o "$OUT_ARM64"

# --- x86_64 ---
echo "🧱 [2/4] x86_64 build..."
clang++ $COMMON_FLAGS -arch x86_64 $OPT_FLAGS "$SRC" $INCLUDE_FLAGS -L"$LIB_X86" -lsoundtouch -o "$OUT_X86"

# --- merge ---
echo "🔗 [3/4] Creating universal dylib..."
lipo -create -output "$OUT_UNI" "$OUT_ARM64" "$OUT_X86"

# --- copy & sign ---
mkdir -p "$APP_DIR"
cp -f "$OUT_UNI" "$APP_DIR/libsoundtouch_ffi.dylib"
chmod +x "$APP_DIR/libsoundtouch_ffi.dylib"
codesign --force --deep --sign - "$APP_DIR/libsoundtouch_ffi.dylib" || echo "⚠️ Codesign skipped."

echo "✅ [4/4] Build complete → $APP_DIR/libsoundtouch_ffi.dylib"
