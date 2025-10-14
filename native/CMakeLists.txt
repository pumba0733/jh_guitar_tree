# native/CMakeLists.txt
cmake_minimum_required(VERSION 3.16)
project(soundtouch_ffi LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# SoundTouch 찾기:
# 1) 패키지 매니저 설치 (macOS: brew install sound-touch | 이름: soundtouch)
# 2) 혹은 서브모듈로 vendor/soundtouch 추가 후 add_subdirectory 사용
# 우선 find_package 경로 시도
find_path(SOUNDTOUCH_INCLUDE_DIR SoundTouch.h
  PATHS /usr/local/include /opt/homebrew/include
        ${CMAKE_SOURCE_DIR}/vendor/soundtouch/include
)
find_library(SOUNDTOUCH_LIBRARY NAMES SoundTouch soundtouch
  PATHS /usr/local/lib /opt/homebrew/lib
        ${CMAKE_SOURCE_DIR}/vendor/soundtouch/lib
)

if (NOT SOUNDTOUCH_INCLUDE_DIR OR NOT SOUNDTOUCH_LIBRARY)
  message(FATAL_ERROR "SoundTouch not found. Install it or vendor it.")
endif()

include_directories(${SOUNDTOUCH_INCLUDE_DIR})

add_library(soundtouch_ffi SHARED
  soundtouch_ffi.cpp
  soundtouch_ffi.h
)

target_link_libraries(soundtouch_ffi PRIVATE ${SOUNDTOUCH_LIBRARY})

if (APPLE)
  set_target_properties(soundtouch_ffi PROPERTIES
    OUTPUT_NAME "soundtouch_ffi"
    PREFIX "lib"
  )
elseif(WIN32)
  set_target_properties(soundtouch_ffi PROPERTIES
    OUTPUT_NAME "soundtouch_ffi"
  )
endif()
