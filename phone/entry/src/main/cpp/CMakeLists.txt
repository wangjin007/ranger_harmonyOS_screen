cmake_minimum_required(VERSION 3.5.0)
project(ohscreen)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(ohscreen SHARED
    napi_init.cpp
    screen_streamer.cpp)

target_link_libraries(ohscreen PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_avscreen_capture.so
    libnative_buffer.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_venc.so
    libnative_window.so)
