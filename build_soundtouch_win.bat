@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo 🎸 [1/4] Building SoundTouch + miniaudio FFI (Release, x64)...

set SRC1=soundtouch_ffi_bridge.cpp
set SRC2=audio_chain_miniaudio.cpp
set INCLUDE_SOUNDTOUCH=..\ThirdParty\soundtouch\include
set INCLUDE_MINIAUDIO=..\ThirdParty\miniaudio\include
set LIB_SOUNDTOUCH=..\ThirdParty\soundtouch\build_x64\soundtouch.lib
set OUT_DLL=libsoundtouch_ffi.dll

rem --- 1️⃣ 클린 빌드 디렉토리 생성 ---
if not exist build mkdir build
cd build

rem --- 2️⃣ x64 빌드 ---
echo 🧱 [2/4] Compiling for x64...
cl /LD /std:c++17 /O2 /EHsc ^
  ..\%SRC1% ..\%SRC2% ^
  /I"%INCLUDE_SOUNDTOUCH%" /I"%INCLUDE_MINIAUDIO%" ^
  "%LIB_SOUNDTOUCH%" ^
  /link /OUT:%OUT_DLL% ^
  /MACHINE:X64 user32.lib kernel32.lib ole32.lib winmm.lib

rem --- 3️⃣ 복사 ---
set APP_RELEASE=..\..\build\windows\x64\runner\Release
if not exist "%APP_RELEASE%\Frameworks" mkdir "%APP_RELEASE%\Frameworks"
copy /Y "%OUT_DLL%" "%APP_RELEASE%\Frameworks\%OUT_DLL%"

rem --- 4️⃣ 완료 ---
echo ✅ [4/4] Windows Release build complete!
echo 📦 Copied to %APP_RELEASE%\Frameworks\%OUT_DLL%
endlocal
