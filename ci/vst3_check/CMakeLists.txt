# ci/vst3_check: the small VST3 host behind the CI checks (see ci/README.md). It needs Steinberg's
# vst3_pluginterfaces (MIT) in sdk/pluginterfaces; the workflow clones it there. Not part of the plugin.
cmake_minimum_required(VERSION 3.16)
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "")
project(vst3_check CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(vst3_check vst3_check.cpp sdk/pluginterfaces/base/funknown.cpp)
target_include_directories(vst3_check PRIVATE sdk)

if(APPLE)
  target_link_libraries(vst3_check PRIVATE "-framework CoreFoundation")
elseif(WIN32)
  target_link_libraries(vst3_check PRIVATE ole32)
else()
  target_link_libraries(vst3_check PRIVATE dl)
endif()
