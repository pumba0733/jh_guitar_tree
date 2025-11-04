#!/bin/bash
APP_PATH="build/macos/Build/Products/Release/guitartree.app/Contents/MacOS"
SRC_FFI="${PROJECT_DIR}/Frameworks/libsoundtouch_ffi.dylib"
SRC_ST="${PROJECT_DIR}/ThirdParty/soundtouch/build_universal/libSoundTouch.2.dylib"


echo "🔍 Checking built app folder..."
if [ ! -d "$APP_PATH" ]; then
  echo "❌ App not found at $APP_PATH"
  exit 1
fi

echo "📦 Copying dylibs..."
cp -f "$SRC_FFI" "$APP_PATH/" && chmod +x "$APP_PATH/libsoundtouch_ffi.dylib"
cp -f "$SRC_ST" "$APP_PATH/" && chmod +x "$APP_PATH/libSoundTouch.2.dylib"

echo "🔏 Code-signing..."
codesign --force --deep --sign - "$APP_PATH/libsoundtouch_ffi.dylib"
codesign --force --deep --sign - "$APP_PATH/libSoundTouch.2.dylib"
codesign --force --deep --sign - "build/macos/Build/Products/Release/guitartree.app"

ls -lh "$APP_PATH" | grep soundtouch
echo "✅ Done"
