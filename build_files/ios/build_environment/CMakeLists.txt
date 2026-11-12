# SPDX-FileCopyrightText: 2023 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

##################################################################################################
#
# This is a build system used by platform maintainers to build library dependencies.
# For users building Blender, we recommend using the pre-compiled libraries from `lib/`
# on all platforms.
#
# This CMake project is usually built through wrappers:
# * Windows: `build_files/build_environment/windows/build_deps.cmd`.
# * macOS and Linux: `make deps` from the blender directory.
#
##################################################################################################

cmake_minimum_required(VERSION 3.10)

set(BLENDER_IOS_DEPS_ROOT "${CMAKE_CURRENT_LIST_DIR}")
set(BLENDER_UPSTREAM_DEPS_ROOT "${BLENDER_IOS_DEPS_ROOT}/../../build_environment")

set(APPLE_TARGET_DEVICE "macos" CACHE STRING "Apple target: macos, ios, or ios-simulator")
set_property(CACHE APPLE_TARGET_DEVICE PROPERTY STRINGS macos ios ios-simulator)
if(APPLE_TARGET_DEVICE STREQUAL "ios" OR APPLE_TARGET_DEVICE STREQUAL "ios-simulator")
  # Cross-compilation must be selected before project() performs compiler checks.
  set(CMAKE_SYSTEM_NAME "iOS" CACHE STRING "Target operating system" FORCE)
endif()

project("BlenderDependencies")
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW) # CMake 3.24+ Set the date/time for extracted files to time of extraction
endif()

if(APPLE_TARGET_DEVICE STREQUAL "ios" OR APPLE_TARGET_DEVICE STREQUAL "ios-simulator")
  set(WITH_APPLE_CROSSPLATFORM ON CACHE BOOL "Build for a non-host Apple platform" FORCE)
  set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "iOS architecture" FORCE)
elseif(APPLE_TARGET_DEVICE STREQUAL "macos")
  set(WITH_APPLE_CROSSPLATFORM OFF CACHE BOOL "Build for a non-host Apple platform" FORCE)
else()
  message(FATAL_ERROR "Unsupported APPLE_TARGET_DEVICE: ${APPLE_TARGET_DEVICE}")
endif()

include(ExternalProject)

list(APPEND CMAKE_MODULE_PATH "${BLENDER_UPSTREAM_DEPS_ROOT}/../cmake/Modules")

macro(blender_ios_include recipe)
  if(EXISTS "${BLENDER_IOS_DEPS_ROOT}/cmake/${recipe}.cmake")
    include("${BLENDER_IOS_DEPS_ROOT}/cmake/${recipe}.cmake")
  else()
    include("${BLENDER_UPSTREAM_DEPS_ROOT}/cmake/${recipe}.cmake")
  endif()
endmacro()

blender_ios_include(options)

# `versions.cmake` needs to be included after `options.cmake`
# due to the `BLENDER_PLATFORM_ARM` variable being needed.
blender_ios_include(versions)
blender_ios_include(download)

if(PACKAGE_DOWNLOAD_ONLY)
  return()
endif()

blender_ios_include(macros)
blender_ios_include(check_software)
# `setup_msys2.cmake` to install `perl`,
# which HIP needs to function for the compiler detection to work properly,
# hence needs to be included before `check_compilers.cmake`.
if(ENABLE_MSYS2)
  blender_ios_include(setup_msys2)
else()
  set(mingw_LIBDIR ${LIBDIR})
endif()
blender_ios_include(check_compilers)
blender_ios_include(harvest)

blender_ios_include(ssl)
blender_ios_include(zlib)
blender_ios_include(zstd)
blender_ios_include(openal)
blender_ios_include(png)
blender_ios_include(jpeg)
blender_ios_include(blosc)
blender_ios_include(pthreads)
blender_ios_include(deflate)
blender_ios_include(imath)
blender_ios_include(brotli)
blender_ios_include(freetype)
if(NOT WITH_APPLE_CROSSPLATFORM)
  blender_ios_include(epoxy)
endif()
blender_ios_include(alembic)
blender_ios_include(opensubdiv)
blender_ios_include(sdl)
if(UNIX)
  blender_ios_include(nasm)
endif()
blender_ios_include(tiff)
if(WIN32)
  blender_ios_include(flexbison)
elseif(UNIX AND NOT APPLE)
  blender_ios_include(flex)
endif()
blender_ios_include(tbb)
blender_ios_include(python)
blender_ios_include(python_cross_environment)
blender_ios_include(llvm)
blender_ios_include(osl)
blender_ios_include(cython)
blender_ios_include(numpy)
blender_ios_include(zstandard)
blender_ios_include(python_site_packages)
blender_ios_include(package_python)
blender_ios_include(openimageio)
blender_ios_include(usd)
blender_ios_include(materialx)
blender_ios_include(openexr)
blender_ios_include(openvdb)
blender_ios_include(potrace)
blender_ios_include(haru)
blender_ios_include(pugixml)
blender_ios_include(fribidi)
blender_ios_include(harfbuzz)
blender_ios_include(xr_openxr_sdk)
if(NOT APPLE)
  if(NOT BLENDER_PLATFORM_ARM)
    blender_ios_include(hiprt)
    blender_ios_include(dpcpp)
    blender_ios_include(dpcpp_deps)
    blender_ios_include(emhash)
    blender_ios_include(parallelhashmap)
    if(NOT WIN32)
      blender_ios_include(igc)
      blender_ios_include(gmmlib)
      blender_ios_include(ocloc)
    endif()
  endif()
endif()
blender_ios_include(ispc)
blender_ios_include(openpgl)
# EMBREE needs to be included after `dpcpp` as it uses it for compiling with GPU support
if(BLENDER_PLATFORM_WINDOWS_ARM)
  # WoA needs EMBREE to be built with the VS Generator + LLVM,
  # put it in its own file to avoid clutter.
  blender_ios_include(embree_windows_arm)
else()
  blender_ios_include(embree)
endif()
blender_ios_include(fmt)
blender_ios_include(robinmap)
blender_ios_include(xml2)
# OpenColorIO and dependencies.
blender_ios_include(expat)
blender_ios_include(pystring)
blender_ios_include(yamlcpp)
blender_ios_include(minizipng)
blender_ios_include(opencolorio)
blender_ios_include(openjph)
blender_ios_include(thorvg)
blender_ios_include(libheif)
blender_ios_include(ffi)

if(BLENDER_PLATFORM_ARM)
  blender_ios_include(sse2neon)
endif()

blender_ios_include(webp)
if(NOT APPLE)
  blender_ios_include(level-zero)
endif()

if(NOT WIN32 OR ENABLE_MSYS2)
  blender_ios_include(gmp)
  blender_ios_include(openjpeg)
  blender_ios_include(sqlite)
  blender_ios_include(fftw)
  blender_ios_include(aom)
  if(NOT WIN32 OR BUILD_MODE STREQUAL Release)
    blender_ios_include(openimagedenoise)
    blender_ios_include(lame)
    blender_ios_include(ogg)
    blender_ios_include(vorbis)
    blender_ios_include(theora)
    blender_ios_include(opus)
    blender_ios_include(vpx)
    blender_ios_include(x264)
    blender_ios_include(x265)
    if(NOT APPLE AND NOT BLENDER_PLATFORM_WINDOWS_ARM)
      blender_ios_include(ffnvcodec)
    endif()
    if(WIN32 AND NOT BLENDER_PLATFORM_WINDOWS_ARM)
      blender_ios_include(amf)
    endif()
    blender_ios_include(ffmpeg)
    blender_ios_include(flac)
    blender_ios_include(sndfile)
    blender_ios_include(ktx)
    if(UNIX)
      if(NOT APPLE)
        blender_ios_include(spnav)
      endif()
    endif()
  endif()
endif()

if(UNIX)
  blender_ios_include(bzip2)
  blender_ios_include(lzma)
endif()

if(UNIX AND NOT APPLE)
  blender_ios_include(wayland_protocols)
  # Can be removed when the build-bot upgrades to v1.20.x or newer.
  blender_ios_include(wayland)
  blender_ios_include(wayland_weston)
endif()
blender_ios_include(shaderc_deps)
blender_ios_include(shaderc)
blender_ios_include(vulkan)
blender_ios_include(vulkan-memory-allocator)
blender_ios_include(spirv-reflect)
blender_ios_include(pybind11)
blender_ios_include(nanobind)
blender_ios_include(manifold)
blender_ios_include(rubberband)
blender_ios_include(abseil)
blender_ios_include(eigen)
blender_ios_include(ceres)
blender_ios_include(draco)
blender_ios_include(meshoptimizer)
blender_ios_include(tracy)
blender_ios_include(jolt)
blender_ios_include(rapidjson)
blender_ios_include(opentimelineio)
# Keep these last.
blender_ios_include(deps_md)
blender_ios_include(cve_check)

if(UNIX)
  # Strip all installed libraries.
  harvest_strip_all_libraries()
endif()
