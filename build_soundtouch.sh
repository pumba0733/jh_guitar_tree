#!/bin/bash
set -e

# 🎧 SmartMediaPlayer FFI Builder (SoundTouch + miniaudio + FFmpeg)
# macOS Universal (arm64 + x86_64)
# Usage: ./build_soundtouch.sh [release]
# Default = debug
#
# 역할:
#  - audio_chain_miniaudio.cpp FFI를 arm64/x86_64로 빌드
#  - universal dylib(libsoundtouch_ffi_universal.dylib) 생성
#  - 앱 번들 Frameworks에 libsoundtouch_ffi.dylib로 복사
#  - FFI 안에 박힌 FFmpeg 절대 경로 → @rpath/lib*.dylib 로 교체
#  - FFI만 코드 서명
#
# ⚠️ FFmpeg 5종(universal) 및 X11 관련 처리는
#    JHGuitarTree_FFmpegSandbox_Plan_v1 Step 1~3에서 이미 완료된 상태를 전제로 함.

MODE="${1:-debug}"
MODE_UPPER=$(echo "$MODE" | tr '[:lower:]' '[:upper:]')

# 프로젝트 루트(guitartree)에서 실행된다고 가정
cd "$(cd "$(dirname "$0")" && pwd)"
echo "📂 PWD = $(pwd)"

echo "🎸 [0/4] Building SoundTouch + miniaudio FFI ($MODE_UPPER, universal)..."

# ─────────────────────────────────────────────
#  경로 정의 (모두 프로젝트 루트 기준)
# ─────────────────────────────────────────────

# C++ FFI 소스
SRC="macos/Frameworks/audio_chain_miniaudio.cpp"

# --- Includes ---
INCLUDE_SOUNDTOUCH="macos/ThirdParty/soundtouch/include"
INCLUDE_MINIAUDIO="macos/ThirdParty/miniaudio"
INCLUDE_FFMPEG="macos/ThirdParty/ffmpeg/include"

# --- Lib dirs ---
LIB_SOUNDTOUCH_ARM64="macos/ThirdParty/soundtouch/build_arm64"
LIB_SOUNDTOUCH_X86="macos/ThirdParty/soundtouch/build_x86_64"

# FFmpeg 라이브러리 디렉토리 (링크용)
LIB_FFMPEG_ARM64="macos/ThirdParty/ffmpeg/arm64/lib"
LIB_FFMPEG_X86="macos/ThirdParty/ffmpeg/x86_64/lib"

# FFmpeg dylib 파일 이름 목록 (의존성 이름 패치용)
FFMPEG_LIB_BASENAMES=(
  "libavformat.60.dylib"
  "libavcodec.60.dylib"
  "libavutil.58.dylib"
  "libswresample.4.dylib"
  "libswscale.7.dylib"
)

OUT_ARM64="libsoundtouch_ffi_arm64.dylib"
OUT_X86="libsoundtouch_ffi_x86_64.dylib"
OUT_UNI="libsoundtouch_ffi_universal.dylib"

COMMON_FLAGS="-std=c++17 -dynamiclib -framework AudioToolbox -framework CoreAudio"
INCLUDE_FLAGS="-I$INCLUDE_SOUNDTOUCH -I$INCLUDE_MINIAUDIO -I$INCLUDE_FFMPEG"

# FFmpeg 링킹 라이브러리 세트
FFMPEG_LINK_LIBS="-lavformat -lavcodec -lavutil -lswresample -lswscale -lz"

if [[ "$MODE" == "release" ]]; then
  OPT_FLAGS="-O3 -DNDEBUG"
  APP_DIR="build/macos/Build/Products/Release/guitartree.app/Contents/Frameworks"
else
  OPT_FLAGS="-g"
  APP_DIR="build/macos/Build/Products/Debug/guitartree.app/Contents/Frameworks"
fi

# FFI가 링크 시점에 바라보는 "옛날 FFmpeg 절대 경로" prefix
# (Step 3에서 사용한 것과 동일하게 유지해야 install_name_tool이 맞춰서 교체 가능)
OLD_FFMPEG_ARM64="/Users/jaehyounglee/Desktop/guitartree/guitartree/macos/ThirdParty/ffmpeg/arm64/lib"
OLD_FFMPEG_X86="/Users/jaehyounglee/Desktop/guitartree/guitartree/macos/thirdparty/ffmpeg_src/build_x86_64/../../ffmpeg/x86_64/lib"

# ─────────────────────────────────────────────
# 0) 소스/폴더 존재 여부 체크
# ─────────────────────────────────────────────
echo "🔍 Checking paths..."
if [[ ! -f "$SRC" ]]; then
  echo "❌ SRC not found: $SRC"
  echo "   → 'ls macos/Frameworks' 해서 audio_chain_miniaudio.cpp 존재 여부 확인 필요."
  exit 1
fi

for d in "$INCLUDE_SOUNDTOUCH" "$INCLUDE_MINIAUDIO" "$INCLUDE_FFMPEG" \
         "$LIB_SOUNDTOUCH_ARM64" "$LIB_SOUNDTOUCH_X86" \
         "$LIB_FFMPEG_ARM64" "$LIB_FFMPEG_X86"; do
  if [[ ! -d "$d" ]]; then
    echo "⚠️  Directory not found: $d"
  fi
done

mkdir -p "$APP_DIR"
echo "📂 APP_DIR = $APP_DIR"

# ─────────────────────────────────────────────
# 1) FFI dylib (arm64)
# ─────────────────────────────────────────────
echo "🧱 [1/4] arm64 FFI build..."
clang++ $COMMON_FLAGS -arch arm64 $OPT_FLAGS "$SRC" \
  $INCLUDE_FLAGS \
  -L"$LIB_SOUNDTOUCH_ARM64" -L"$LIB_FFMPEG_ARM64" \
  -lsoundtouch $FFMPEG_LINK_LIBS \
  -o "$OUT_ARM64"

# ─────────────────────────────────────────────
# 2) FFI dylib (x86_64)
# ─────────────────────────────────────────────
echo "🧱 [2/4] x86_64 FFI build..."
clang++ $COMMON_FLAGS -arch x86_64 $OPT_FLAGS "$SRC" \
  $INCLUDE_FLAGS \
  -L"$LIB_SOUNDTOUCH_X86" -L"$LIB_FFMPEG_X86" \
  -lsoundtouch $FFMPEG_LINK_LIBS \
  -o "$OUT_X86"

# ─────────────────────────────────────────────
# 3) FFI universal dylib 생성 + 앱 번들로 복사
# ─────────────────────────────────────────────
echo "🔗 [3/4] Creating universal FFI dylib..."
lipo -create -output "$OUT_UNI" "$OUT_ARM64" "$OUT_X86"

FFI_BUNDLE_PATH="$APP_DIR/libsoundtouch_ffi.dylib"
cp -f "$OUT_UNI" "$FFI_BUNDLE_PATH"
chmod +x "$FFI_BUNDLE_PATH"

echo "📦 FFI dylib -> $FFI_BUNDLE_PATH"

# ─────────────────────────────────────────────
# 4) FFI 내부 FFmpeg 의존성 경로 → @rpath 로 정리 + 코드 서명
# ─────────────────────────────────────────────
echo "🧩 [4/4] Fixing FFmpeg deps in FFI → @rpath, then codesign..."

# 4-1) FFI 안에 박힌 FFmpeg 절대 경로들을 @rpath 로 교체
for name in "${FFMPEG_LIB_BASENAMES[@]}"; do
  install_name_tool -change "$OLD_FFMPEG_ARM64/$name" "@rpath/$name" "$FFI_BUNDLE_PATH" 2>/dev/null || true
  install_name_tool -change "$OLD_FFMPEG_X86/$name"   "@rpath/$name" "$FFI_BUNDLE_PATH" 2>/dev/null || true
done

# 4-3) FFI 코드 서명
codesign --force --deep --sign - "$FFI_BUNDLE_PATH" || echo "⚠️ sign warn (FFI)"

# ─────────────────────────────────────────────
# 5) FFmpeg core dylib 5종 universal 생성 + 앱 번들로 복사
# ─────────────────────────────────────────────
echo "🎬 [5/5] Packing FFmpeg core dylibs into app bundle..."

for name in "${FFMPEG_LIB_BASENAMES[@]}"; do
  SRC_ARM64="$LIB_FFMPEG_ARM64/$name"
  SRC_X86="$LIB_FFMPEG_X86/$name"
  DEST="$APP_DIR/$name"

  if [[ -f "$SRC_ARM64" && -f "$SRC_X86" ]]; then
    echo "  🔗 FFmpeg universal: $name"
    lipo -create -output "$DEST" "$SRC_ARM64" "$SRC_X86"

    # 5-1) install_name 을 @rpath로 통일
    install_name_tool -id "@rpath/$name" "$DEST" || true

    # 5-2) 안에 박힌 다른 FFmpeg 절대 경로도 전부 @rpath로 교체
    for dep in "${FFMPEG_LIB_BASENAMES[@]}"; do
      # 자기 자신은 스킵
      if [[ "$dep" == "$name" ]]; then
        continue
      fi

      install_name_tool -change "$OLD_FFMPEG_ARM64/$dep" "@rpath/$dep" "$DEST" 2>/dev/null || true
      install_name_tool -change "$OLD_FFMPEG_X86/$dep"   "@rpath/$dep" "$DEST" 2>/dev/null || true
    done

    # 5-3) 서명
    codesign --force --deep --sign - "$DEST" || echo "⚠️ sign warn ($name)"
  else
    echo "  ⚠️ Missing FFmpeg slice for $name (arm64/x86_64), skip."
  fi
done

# ─────────────────────────────────────────────
# 6) SoundTouch dylib(universal) 복사 + 서명
# ─────────────────────────────────────────────

echo ""
echo "==== [STEP 6] SoundTouch universal dylib → app bundle ===="

# 스크립트 파일이 있는 위치(= 리포지토리 루트 기준)로부터 절대경로 계산
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SND_NAME="libSoundTouch.2.dylib"

# SoundTouch 유니버설 빌드 위치
SND_UNI_DIR="${SCRIPT_DIR}/macos/ThirdParty/soundtouch/build_universal"
SND_UNI="${SND_UNI_DIR}/${SND_NAME}"

# Debug / Release 앱 번들 Frameworks 경로 둘 다 준비
APP_DEBUG_FW="${SCRIPT_DIR}/build/macos/Build/Products/Debug/guitartree.app/Contents/Frameworks"
APP_RELEASE_FW="${SCRIPT_DIR}/build/macos/Build/Products/Release/guitartree.app/Contents/Frameworks"

echo "  SCRIPT_DIR      = ${SCRIPT_DIR}"
echo "  SND_UNI         = ${SND_UNI}"
echo "  APP_DEBUG_FW    = ${APP_DEBUG_FW}"
echo "  APP_RELEASE_FW  = ${APP_RELEASE_FW}"

if [[ ! -f "${SND_UNI}" ]]; then
  echo "⚠️  SoundTouch universal dylib not found:"
  echo "    ${SND_UNI}"
  echo "    → 'ls ${SND_UNI_DIR}' 로 파일명을 다시 확인해봐."
else
  # Debug / Release 둘 다 존재하면 둘 다에 복사
  for APP_FW in "${APP_DEBUG_FW}" "${APP_RELEASE_FW}"; do
    if [[ -d "${APP_FW}" ]]; then
      echo "🎚  Copying SoundTouch → ${APP_FW}/${SND_NAME}"
      cp -f "${SND_UNI}" "${APP_FW}/${SND_NAME}"
      chmod +x "${APP_FW}/${SND_NAME}" || true

      # install_name 을 @rpath 기준으로 통일
      install_name_tool -id "@rpath/${SND_NAME}" "${APP_FW}/${SND_NAME}" || true

      # 코드 서명
      codesign --force --deep --sign - "${APP_FW}/${SND_NAME}" \
        || echo "⚠️  codesign warning (SoundTouch @ ${APP_FW})"
    else
      echo "ℹ️  App Frameworks dir not found (skip): ${APP_FW}"
    fi
  done
fi

echo "==== [STEP 6] SoundTouch done ===="
echo ""





echo "✅ FFI build complete → $FFI_BUNDLE_PATH"
echo "   (FFmpeg 5종은 Step 1~3에서 이미 universal + @rpath 상태로 고정됨)"
