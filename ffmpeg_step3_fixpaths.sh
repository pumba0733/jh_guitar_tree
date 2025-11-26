#!/bin/bash
set -e

# JHGuitarTree_FFmpegSandbox_Plan_v1 — Step 3 (마무리)
# FFmpeg 5종 및 libsoundtouch_ffi.dylib 내부의 "절대경로 FFmpeg 의존성"을
# 전부 @rpath/....dylib 형태로 교체해서
# 앱 번들 Frameworks 안에서만 닫히도록 만드는 단계.

cd "/Users/jaehyounglee/Desktop/guitartree/guitartree"

APP="build/macos/Build/Products/Debug/guitartree.app"
FW="$APP/Contents/Frameworks"

if [ ! -d "$FW" ]; then
  echo "❌ Frameworks 폴더가 없음. 먼저 flutter build macos 또는 Xcode에서 한 번 빌드해줘."
  exit 1
fi

FFMPEG_LIBS=(
  "libavcodec.60.dylib"
  "libavformat.60.dylib"
  "libavutil.58.dylib"
  "libswresample.4.dylib"
  "libswscale.7.dylib"
)

# 절대 경로 prefix 들 (지금 otool 로그에 찍힌 그대로)
X86_PREFIX="/Users/jaehyounglee/Desktop/guitartree/guitartree/macos/thirdparty/ffmpeg_src/build_x86_64/../../ffmpeg/x86_64/lib"
ARM_PREFIX="/Users/jaehyounglee/Desktop/guitartree/guitartree/macos/ThirdParty/ffmpeg/arm64/lib"

echo "APP: $APP"
echo "FW : $FW"
echo "X86: $X86_PREFIX"
echo "ARM: $ARM_PREFIX"

cd "$FW"

echo ""
echo "== 1) FFmpeg 5종 내부 의존성 절대경로 → @rpath 로 교체 =="

for target in "${FFMPEG_LIBS[@]}"; do
  if [ ! -f "$target" ]; then
    echo "⚠️  없음 (skip): $target"
    continue
  fi

  echo "patch: $target"

  # x86_64 빌드 경로에서 온 의존성들
  install_name_tool -change "$X86_PREFIX/libavcodec.60.dylib"   "@rpath/libavcodec.60.dylib"   "$target" 2>/dev/null || true
  install_name_tool -change "$X86_PREFIX/libavformat.60.dylib"  "@rpath/libavformat.60.dylib"  "$target" 2>/dev/null || true
  install_name_tool -change "$X86_PREFIX/libavutil.58.dylib"    "@rpath/libavutil.58.dylib"    "$target" 2>/dev/null || true
  install_name_tool -change "$X86_PREFIX/libswresample.4.dylib" "@rpath/libswresample.4.dylib" "$target" 2>/dev/null || true
  install_name_tool -change "$X86_PREFIX/libswscale.7.dylib"    "@rpath/libswscale.7.dylib"    "$target" 2>/dev/null || true

  # arm64 빌드 경로에서 온 의존성들
  install_name_tool -change "$ARM_PREFIX/libavcodec.60.dylib"   "@rpath/libavcodec.60.dylib"   "$target" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libavformat.60.dylib"  "@rpath/libavformat.60.dylib"  "$target" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libavutil.58.dylib"    "@rpath/libavutil.58.dylib"    "$target" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libswresample.4.dylib" "@rpath/libswresample.4.dylib" "$target" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libswscale.7.dylib"    "@rpath/libswscale.7.dylib"    "$target" 2>/dev/null || true
done

echo ""
echo "== 2) libsoundtouch_ffi.dylib 안의 절대경로도 @rpath 로 교체 =="

FFI="libsoundtouch_ffi.dylib"

if [ -f "$FFI" ]; then
  echo "patch: $FFI"

  # arm64 쪽에서 FFmpeg 5종을 절대경로로 물고 있는 부분들
  install_name_tool -change "$ARM_PREFIX/libavformat.60.dylib"  "@rpath/libavformat.60.dylib"  "$FFI" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libavcodec.60.dylib"   "@rpath/libavcodec.60.dylib"   "$FFI" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libavutil.58.dylib"    "@rpath/libavutil.58.dylib"    "$FFI" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libswresample.4.dylib" "@rpath/libswresample.4.dylib" "$FFI" 2>/dev/null || true
  install_name_tool -change "$ARM_PREFIX/libswscale.7.dylib"    "@rpath/libswscale.7.dylib"    "$FFI" 2>/dev/null || true
else
  echo "⚠️  Frameworks에 libsoundtouch_ffi.dylib 없음"
fi

echo ""
echo "== 3) 최종 otool -L 재확인 (FFmpeg 5종 + FFI) =="

for f in "${FFMPEG_LIBS[@]}"; do
  if [ -f "$f" ]; then
    echo ""
    echo "-- $f --"
    otool -L "$f"
  else
    echo "⚠️  없음: $f"
  fi
done

echo ""
echo "-- libsoundtouch_ffi.dylib --"
if [ -f "$FFI" ]; then
  otool -L "$FFI"
else
  echo "⚠️  없음: $FFI"
fi

echo ""
echo "== [END] Step 3: 절대 경로 → @rpath 치환 + 최종 검증 로그 =="
