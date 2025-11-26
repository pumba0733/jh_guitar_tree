set -e

APP_ROOT="build/macos/Build/Products/Debug/guitartree.app"
BIN="$APP_ROOT/Contents/MacOS/guitartree"
FW_DIR="$APP_ROOT/Contents/Frameworks"

echo "== [1] 메인 실행파일 의존성 =="
if [ -f "$BIN" ]; then
  otool -L "$BIN"
else
  echo "  (실행파일을 찾지 못함: $BIN)"
fi

echo ""
echo "== [2] Frameworks 내 핵심 dylib 의존성 =="

cd "$FW_DIR" 2>/dev/null || {
  echo "Frameworks 디렉토리 없음: $FW_DIR"
  exit 1
}

TARGETS=(
  "guitartree.debug.dylib"
  "libsoundtouch_ffi.dylib"
  "libSoundTouch.2.dylib"
  "libavcodec.60.dylib"
  "libavformat.60.dylib"
  "libavutil.58.dylib"
  "libswresample.4.dylib"
  "libswscale.7.dylib"
  "libavcodec.dylib"
  "libavformat.dylib"
  "libavutil.dylib"
  "libswresample.dylib"
  "libswscale.dylib"
)

for f in "${TARGETS[@]}"; do
  if [ -f "$f" ]; then
    echo ""
    echo "---- $f ----"
    otool -L "$f"
  fi
done

echo ""
echo "== [3] 위험한 절대경로 스캔 (/opt/homebrew, /usr/local, /Users) =="

# 메인 바이너리 + Frameworks 내 모든 dylib을 한 번에 검사
echo ""
echo "[grep] /opt/homebrew, /usr/local, /Users ..."
if otool -L "$BIN" "$FW_DIR"/*.dylib 2>/dev/null | egrep "/opt/homebrew|/usr/local|/Users/" ; then
  echo ""
  echo "⚠ 위에 나온 항목들은 '앱 번들 밖'의 경로를 참조 중이다."
  echo "  → Step 5에서 반드시 제거해야 할 대상."
else
  echo "✅ 메인 + dylib에서 /opt/homebrew, /usr/local, /Users 경로는 발견되지 않음."
fi

echo ""
echo "== [4] X11 / XCB 의존성 스캔 (libX11, libxcb) =="

if otool -L "$FW_DIR"/*.dylib 2>/dev/null | egrep "libX11|libxcb" ; then
  echo ""
  echo "⚠ 위에 나온 항목들은 X11/XCB 계열 의존성이다."
  echo "  → FFmpeg no-X11 빌드가 제대로 적용되지 않은 녀석이 섞여있을 가능성."
else
  echo "✅ Frameworks 내 dylib에서 libX11/libxcb 의존성은 발견되지 않음."
fi

echo ""
echo "== [5] 주요 대상에 대한 아키텍처 확인 (lipo -info) =="

for f in libavcodec.60.dylib libavformat.60.dylib libavutil.58.dylib libswresample.4.dylib libswscale.7.dylib libsoundtouch_ffi.dylib; do
  if [ -f "$f" ]; then
    echo ""
    echo "lipo -info $f"
    lipo -info "$f" || true
  fi
done

echo ""
echo "== Step 5 사전 점검 스크립트 완료 =="
