#!/bin/bash
set -e
cd "$(dirname "$0")/macos/frameworks"

echo "🎸 [1/5] Building SoundTouch + miniaudio FFI (Release, universal)..."

SRC1="soundtouch_ffi_bridge.cpp"
SRC2="audio_chain_miniaudio.cpp"
INCLUDE_SOUNDTOUCH="../ThirdParty/soundtouch/include"
INCLUDE_MINIAUDIO="../ThirdParty/miniaudio"


# --- arm64 ---
echo "🧱 [2/5] arm64 build..."
clang++ -std=c++17 -arch arm64 -O3 -DNDEBUG -dynamiclib "$SRC1" "$SRC2" \
  -I"$INCLUDE_SOUNDTOUCH" -I"$INCLUDE_MINIAUDIO" \
  -L"../ThirdParty/soundtouch/build_arm64" \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_arm64.dylib

# --- x86_64 ---
echo "🧱 [3/5] x86_64 build..."
clang++ -std=c++17 -arch x86_64 -O3 -DNDEBUG -dynamiclib "$SRC1" "$SRC2" \
  -I"$INCLUDE_SOUNDTOUCH" -I"$INCLUDE_MINIAUDIO" \
  -L"../ThirdParty/soundtouch/build_x86_64" \
  -lsoundtouch -framework AudioToolbox -framework CoreAudio \
  -o libsoundtouch_ffi_x86_64.dylib

# --- universal merge ---
echo "🔗 [4/5] Merging into universal binary..."
lipo -create -output libsoundtouch_ffi_universal.dylib \
  libsoundtouch_ffi_arm64.dylib libsoundtouch_ffi_x86_64.dylib

# --- copy & sign (Release) ---
APP_RELEASE="../../build/macos/Build/Products/Release/guitartree.app/Contents/Frameworks"
mkdir -p "$APP_RELEASE"

echo "📦 Copying to $APP_RELEASE"
cp -f libsoundtouch_ffi_universal.dylib "$APP_RELEASE/libsoundtouch_ffi.dylib"
chmod +x "$APP_RELEASE/libsoundtouch_ffi.dylib"

echo "🔏 Codesigning..."
codesign --force --deep --sign - "$APP_RELEASE/libsoundtouch_ffi.dylib"

echo "✅ [5/5] Release universal build complete!"
