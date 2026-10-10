cmake_minimum_required(VERSION 3.21)
project(qualityav_capture LANGUAGES CXX)

# First-party native background capture helper for the Forge audiovisual route.
# It records one original muxed MP4 (Windows.Graphics.Capture video + WASAPI
# loopback audio) and reports process-creation, HWND and QPC source association
# as newline-delimited JSON on stdout. Every source file listed below is
# authored in this repository; no sample or third-party source is vendored and
# no prebuilt binary is shipped. Build output is a local, untracked artifact.

if(NOT WIN32)
  message(FATAL_ERROR "qualityav-capture targets Windows only (WASAPI, Windows.Graphics.Capture, Media Foundation).")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(qualityav-capture
  src/main.cpp
  src/session.cpp
  src/process_identity.cpp
  src/audio_capture.cpp
  src/video_capture.cpp
  src/mux_writer.cpp)

target_include_directories(qualityav-capture PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

# <audioclientactivationparams.h> only exposes AUDIOCLIENT_ACTIVATION_PARAMS when
# NTDDI_VERSION >= NTDDI_WIN10_FE (0x0A00000A). sdkddkver.h derives NTDDI_VERSION
# from _WIN32_WINNT as ver##0000, so _WIN32_WINNT=0x0A00 alone would yield
# 0x0A000000 and hide the process-loopback activation types. Pin both.
target_compile_definitions(qualityav-capture PRIVATE
  UNICODE
  _UNICODE
  WIN32_LEAN_AND_MEAN
  NOMINMAX
  _WIN32_WINNT=0x0A00
  NTDDI_VERSION=0x0A00000A)

if(MSVC)
  target_compile_options(qualityav-capture PRIVATE /W4 /permissive- /EHsc /Zc:__cplusplus)
endif()

# System libraries only, all resolved from the Windows 10/11 SDK:
#   ole32       COM lifetime and PROPVARIANT helpers
#   mmdevapi    ActivateAudioInterfaceAsync, MMDeviceEnumerator, IMMDevice
#   mfplat      MFStartup, media types, samples, buffers
#   mfreadwrite IMFSinkWriter (mux original audio+video into MP4)
#   mfuuid      MF_MT_* / MFVideoFormat_* / MFAudioFormat_* GUIDs
#   d3d11, dxgi D3D11 device, staging copies of capture frames
#   windowsapp  C++/WinRT activation for Windows.Graphics.Capture
#   user32      HWND validation and window owner lookup
target_link_libraries(qualityav-capture PRIVATE
  ole32
  mmdevapi  # ActivateAudioInterfaceAsync, MMDeviceEnumerator
  mfplat
  mfreadwrite
  mfuuid
  d3d11
  dxgi
  windowsapp
  user32)

add_executable(qualityav-register src/registration.cpp src/process_identity.cpp)
target_include_directories(qualityav-register PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_compile_definitions(qualityav-register PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A00000A)
if(MSVC)
  target_compile_options(qualityav-register PRIVATE /W4 /permissive- /EHsc /Zc:__cplusplus)
endif()
target_link_libraries(qualityav-register PRIVATE ole32 d3d11 dxgi windowsapp user32)
