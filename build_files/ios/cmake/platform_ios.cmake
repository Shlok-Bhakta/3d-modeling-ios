# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Keep iOS platform wiring separate from the desktop branch below. The target
# uses Blender's full feature profile, but its libraries must come from the
# cross-compiled sysroot instead of AppKit, Carbon, or host SDK packages.
set(BLENDER_PLATFORM_CREATOR_CMAKE
  "${CMAKE_SOURCE_DIR}/build_files/ios/cmake/creator_ios.cmake"
)
set(GHOST_PLATFORM_CMAKE
  "${CMAKE_SOURCE_DIR}/build_files/ios/cmake/ghost_ios.cmake"
)
set(WINDOWMANAGER_PLATFORM_CMAKE
  "${CMAKE_SOURCE_DIR}/build_files/ios/cmake/windowmanager_ios.cmake"
)
set(BLENDER_PLATFORM_FILE_MENU_SOURCE fsmenu_system_ios.mm)
set(BLENDER_PLATFORM_USD_HOOK_SOURCE intern/usd_hook_stub.cc)
add_definitions(
  -DBLENDER_PYTHON_PLATFORM_HEADER=\"bpy_interface_ios.hh\"
  -DBLENDER_PLATFORM_RESOURCE_DIR=\"Assets\"
  -DBLENDER_PLATFORM_DEFAULT_UI_SCALE=1.65f
  -DQUADRIFLOW_SUBPROCESS_SUPPORT=0
  -DBLENDER_METAL_PLATFORM_HEADER=\"mtl_platform_ios.hh\"
)
if(WITH_APPLE_CROSSPLATFORM)
  if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "WITH_APPLE_CROSSPLATFORM requires CMAKE_SYSTEM_NAME=iOS")
  endif()
  if(NOT DEFINED LIBDIR OR NOT EXISTS "${LIBDIR}")
    message(FATAL_ERROR "iOS requires a harvested dependency sysroot in LIBDIR: ${LIBDIR}")
  endif()
  if(NOT DEFINED IOS_HOST_TOOLS_DIR)
    message(FATAL_ERROR "iOS requires revision-matched native tools in IOS_HOST_TOOLS_DIR")
  endif()

  foreach(_host_tool makesdna makesrna datatoc msgfmt shader_tool)
    if(NOT EXISTS "${IOS_HOST_TOOLS_DIR}/${_host_tool}")
      message(FATAL_ERROR "Missing iOS host tool: ${IOS_HOST_TOOLS_DIR}/${_host_tool}")
    endif()
    if(NOT TARGET ${_host_tool})
      add_executable(${_host_tool} IMPORTED GLOBAL)
      set_property(TARGET ${_host_tool} PROPERTY
        IMPORTED_LOCATION "${IOS_HOST_TOOLS_DIR}/${_host_tool}"
      )
    endif()
  endforeach()
  unset(_host_tool)

  set(WITH_OPENGL_BACKEND OFF CACHE BOOL "OpenGL is unavailable on iOS" FORCE)
  set(WITH_VULKAN_BACKEND OFF CACHE BOOL "Vulkan is unavailable on iOS" FORCE)
  set(WITH_SDL OFF CACHE BOOL "SDL windowing is unused on iOS" FORCE)
  set(WITH_INPUT_NDOF OFF CACHE BOOL "NDOF is unavailable on iOS" FORCE)
  set(WITH_BLENDER_THUMBNAILER OFF CACHE BOOL "No Finder extension on iOS" FORCE)

  file(GLOB LIB_SUBDIRS "${LIBDIR}/*")
  set(CMAKE_PREFIX_PATH ${LIB_SUBDIRS})
  set(CMAKE_FIND_FRAMEWORK NEVER)

  # Source generators execute on the build host even when the target embeds
  # Python. The target library and standard library always come from LIBDIR.
  find_program(PYTHON_EXECUTABLE NAMES python3.13 REQUIRED)

  include("${CMAKE_SOURCE_DIR}/build_files/cmake/host_tool_features.cmake")
  blender_validate_host_tool_features("${IOS_HOST_TOOLS_DIR}/makesrna.features")

  if(WITH_PYTHON)
    set(PYTHON_VERSION "3.13")
    set(PYTHON_INCLUDE_DIR "${LIBDIR}/python/Python.framework/Headers")
    set(PYTHON_INCLUDE_CONFIG_DIR "${PYTHON_INCLUDE_DIR}")
    set(PYTHON_INCLUDE_DIRS "${PYTHON_INCLUDE_DIR}")
    set(PYTHON_LIBRARY "${LIBDIR}/python/Python.framework/Python")
    set(PYTHON_LIBRARIES "${PYTHON_LIBRARY}")
    set(PYTHON_LIBPATH "${LIBDIR}/python/lib")
    set(PYTHON_SITE_PACKAGES "${PYTHON_LIBPATH}/python${PYTHON_VERSION}/site-packages")
    set(PYTHON_LINKFLAGS "")
    foreach(_python_required_path
        "${PYTHON_INCLUDE_DIR}/Python.h"
        "${PYTHON_LIBRARY}"
        "${PYTHON_LIBPATH}/python${PYTHON_VERSION}/os.py"
      )
      if(NOT EXISTS "${_python_required_path}")
        message(FATAL_ERROR "Incomplete iOS Python dependency: ${_python_required_path}")
      endif()
    endforeach()
    unset(_python_required_path)
  endif()

  set(ZLIB_ROOT "${LIBDIR}/zlib")
  find_package(ZLIB REQUIRED)

  set(FREETYPE_ROOT_DIR "${LIBDIR}/freetype")
  find_package(Freetype REQUIRED)
  set(BROTLI_LIBRARIES
    "${LIBDIR}/brotli/lib/libbrotlicommon-static.a"
    "${LIBDIR}/brotli/lib/libbrotlidec-static.a"
  )

  set(libdeflate_ROOT "${LIBDIR}/deflate")
  find_package(OpenEXR REQUIRED CONFIG)
  set(PNG_ROOT "${LIBDIR}/png")
  find_package(PNG REQUIRED)
  set(JPEG_ROOT "${LIBDIR}/jpeg")
  find_package(JPEG REQUIRED)
  set(fmt_ROOT "${LIBDIR}/fmt")
  find_package(fmt REQUIRED CONFIG)

  # Static TIFF and OpenImageIO exports retain these dependency target names.
  if(NOT TARGET CMath::CMath)
    add_library(CMath::CMath INTERFACE IMPORTED)
  endif()
  set(OpenJPEG_DIR "${LIBDIR}/openjpeg/lib/cmake/openjpeg-2.5")
  find_package(OpenJPEG REQUIRED CONFIG)
  if(WITH_IMAGE_WEBP)
    set(WEBP_ROOT_DIR "${LIBDIR}/webp")
    find_package(WebP REQUIRED)
  endif()
  foreach(_webp_component webp webpdemux libwebpmux sharpyuv)
    if(NOT TARGET WebP::${_webp_component})
      add_library(WebP::${_webp_component} STATIC IMPORTED)
      if(_webp_component STREQUAL "libwebpmux")
        set(_webp_archive webpmux)
      else()
        set(_webp_archive ${_webp_component})
      endif()
      set_target_properties(WebP::${_webp_component} PROPERTIES
        IMPORTED_LOCATION "${LIBDIR}/webp/lib/lib${_webp_archive}.a"
        INTERFACE_INCLUDE_DIRECTORIES "${LIBDIR}/webp/include"
      )
    endif()
  endforeach()
  # WebP's static archive calls into SharpYUV, but its generated package does
  # not preserve that private dependency for static consumers.
  set_property(TARGET WebP::webp APPEND PROPERTY
    INTERFACE_LINK_LIBRARIES WebP::sharpyuv
  )
  unset(_webp_archive)
  unset(_webp_component)

  set(minizip-ng_ROOT "${LIBDIR}/minizipng")
  set(minizip-ng_INCLUDE_DIR "${LIBDIR}/minizipng/include/minizip-ng/minizip")
  set(minizip-ng_LIBRARY "${LIBDIR}/minizipng/lib/libminizip.a")
  set(minizip-ng_STATIC_LIBRARY ON)
  # OpenImageIO's static export references this namespaced target even when
  # Blender's own PugiXML feature is disabled.
  set(pugixml_DIR "${LIBDIR}/pugixml/lib/cmake/pugixml")
  find_package(pugixml REQUIRED CONFIG)
  if(TARGET pugixml AND NOT TARGET pugixml::pugixml)
    add_library(pugixml::pugixml ALIAS pugixml)
  endif()
  if(WITH_PUGIXML)
    set(PUGIXML_ROOT_DIR "${LIBDIR}/pugixml")
    find_package(PugiXML REQUIRED)
  endif()

  find_package(OpenImageIO REQUIRED CONFIG)
  find_package(OpenColorIO 2.0.0 REQUIRED CONFIG)
  find_package(Eigen3 REQUIRED CONFIG)
  set(ZSTD_ROOT_DIR "${LIBDIR}/zstd")
  find_package(Zstd REQUIRED)

  if(WITH_OPENSUBDIV)
    set(OPENSUBDIV_ROOT_DIR "${LIBDIR}/opensubdiv")
    find_package(OpenSubdiv REQUIRED)
  endif()

  if(WITH_TBB)
    set(TBB_DIR "${LIBDIR}/tbb/lib/cmake/TBB")
    find_package(TBB 2021.13.0 REQUIRED CONFIG)
    set(TBB_LIBRARIES TBB::tbb)
    get_target_property(TBB_INCLUDE_DIRS TBB::tbb INTERFACE_INCLUDE_DIRECTORIES)
  endif()

  set(METAL_LIBRARY "${CMAKE_OSX_SYSROOT}/System/Library/Frameworks/Metal.framework")

  if(WITH_ALEMBIC)
    set(ALEMBIC_ROOT_DIR "${LIBDIR}/alembic")
    find_package(Alembic REQUIRED)
  endif()

  if(WITH_MATERIALX)
    set(MaterialX_DIR "${LIBDIR}/materialx/lib/cmake/MaterialX")
    find_package(MaterialX REQUIRED CONFIG)
  endif()

  if(WITH_USD)
    set(USD_ROOT_DIR "${LIBDIR}/usd")
    find_package(USD REQUIRED)
  endif()

  if(WITH_CODEC_FFMPEG)
    set(FFMPEG_ROOT_DIR "${LIBDIR}/ffmpeg")
    set(FFMPEG_FIND_COMPONENTS
      avcodec avdevice avfilter avformat avutil swresample swscale
    )
    find_package(FFmpeg REQUIRED)
    # FFmpeg's static archives retain the codec libraries used by its iOS
    # profile. Keep them after the FFmpeg archives in static link order.
    list(APPEND FFMPEG_LIBRARIES
      "${LIBDIR}/lame/lib/libmp3lame.a"
      "${LIBDIR}/openjpeg/lib/libopenjp2.a"
      "${LIBDIR}/opus/lib/libopus.a"
      "${LIBDIR}/theora/lib/libtheora.a"
      "${LIBDIR}/theora/lib/libtheoradec.a"
      "${LIBDIR}/theora/lib/libtheoraenc.a"
      "${LIBDIR}/vorbis/lib/libvorbis.a"
      "${LIBDIR}/vorbis/lib/libvorbisenc.a"
      "${LIBDIR}/vorbis/lib/libvorbisfile.a"
      "${LIBDIR}/ogg/lib/libogg.a"
      "${LIBDIR}/vpx/lib/libvpx.a"
      "${LIBDIR}/zlib/lib/libz.a"
    )
  endif()

  if(WITH_CODEC_SNDFILE)
    set(SNDFILE_ROOT_DIR "${LIBDIR}/sndfile")
    find_package(SndFile REQUIRED)
    list(APPEND LIBSNDFILE_LIBRARIES
      "${LIBDIR}/flac/lib/libFLAC.a"
      "${LIBDIR}/ogg/lib/libogg.a"
      "${LIBDIR}/vorbis/lib/libvorbis.a"
      "${LIBDIR}/vorbis/lib/libvorbisenc.a"
      "${LIBDIR}/opus/lib/libopus.a"
    )
  endif()

  if(WITH_FFTW3)
    set(FFTW3_ROOT_DIR "${LIBDIR}/fftw3")
    find_package(Fftw3 REQUIRED)
  endif()

  if(WITH_OPENAL)
    # Audaspace includes OpenAL's headers as <al.h>/<alc.h>, while OpenAL
    # Soft installs them below include/AL on Apple platforms.
    set(OPENAL_INCLUDE_DIR "${LIBDIR}/openal/include/AL")
    set(OPENAL_LIBRARY "${LIBDIR}/openal/lib/libopenal.a")
    find_package(OpenAL REQUIRED)
  endif()

  if(WITH_OPENIMAGEDENOISE)
    set(OPENIMAGEDENOISE_ROOT_DIR "${LIBDIR}/openimagedenoise")
    # OIDN 2.x names its static support archives `core` and `device_metal`.
    # Pin the legacy `common` probe so it cannot resolve an unrelated host
    # library with the same generic name.
    set(OPENIMAGEDENOISE_COMMON_LIBRARY
      "${LIBDIR}/openimagedenoise/lib/libOpenImageDenoise_core.a"
      CACHE FILEPATH "" FORCE
    )
    find_package(OpenImageDenoise REQUIRED)
    set(OPENIMAGEDENOISE_LIBRARIES
      "${LIBDIR}/openimagedenoise/lib/libOpenImageDenoise.a"
      "${LIBDIR}/openimagedenoise/lib/libOpenImageDenoise_core.a"
      "${LIBDIR}/openimagedenoise/lib/libOpenImageDenoise_device_metal.a"
    )
  endif()

  if(WITH_EMBREE)
    set(embree_DIR "${LIBDIR}/embree/lib/cmake/embree-4.4.1")
    find_package(Embree 4.0.0 REQUIRED)
  endif()
  if(WITH_CYCLES AND WITH_CYCLES_PATH_GUIDING)
    set(openpgl_DIR "${LIBDIR}/openpgl/lib/cmake/openpgl-0.7.1")
    find_package(openpgl REQUIRED CONFIG)
    get_target_property(OPENPGL_LIBRARIES openpgl::openpgl LOCATION)
    get_target_property(OPENPGL_INCLUDE_DIR openpgl::openpgl INTERFACE_INCLUDE_DIRECTORIES)
  endif()

  if(WITH_OPENVDB)
    set(OPENVDB_ROOT_DIR "${LIBDIR}/openvdb")
    find_package(OpenVDB REQUIRED)
    set(OPENVDB_DEFINITIONS "")
    list(APPEND OPENVDB_LIBRARIES
      "${LIBDIR}/blosc/lib/libblosc.a"
      "${LIBDIR}/zlib/lib/libz.a"
    )
  endif()
  if(WITH_NANOVDB)
    set(NANOVDB_ROOT_DIR "${LIBDIR}/openvdb")
    find_package(NanoVDB REQUIRED)
  endif()

  if(WITH_POTRACE)
    set(POTRACE_ROOT_DIR "${LIBDIR}/potrace")
    find_package(Potrace REQUIRED)
  endif()
  if(WITH_GMP)
    set(GMP_ROOT_DIR "${LIBDIR}/gmp")
    find_package(GMP REQUIRED)
  endif()
  if(WITH_HARU)
    set(HARU_ROOT_DIR "${LIBDIR}/haru")
    find_package(Haru REQUIRED)
  endif()
  if(WITH_MANIFOLD)
    set(manifold_DIR "${LIBDIR}/manifold/lib/cmake/manifold")
    find_package(manifold REQUIRED CONFIG)
  endif()
  if(WITH_RUBBERBAND)
    set(RUBBERBAND_ROOT_DIR "${LIBDIR}/rubberband")
    find_package(Rubberband REQUIRED)
  endif()

  if(WITH_LIBMV)
    set(Ceres_DIR "${LIBDIR}/ceres/lib/cmake/Ceres")
    find_package(Ceres REQUIRED CONFIG)
  endif()
  if(WITH_DRACO)
    set(draco_DIR "${LIBDIR}/draco/share/cmake/draco")
    find_package(draco REQUIRED CONFIG)
  endif()
  if(WITH_MESHOPTIMIZER)
    set(meshoptimizer_DIR "${LIBDIR}/meshoptimizer/lib/cmake/meshoptimizer")
    find_package(meshoptimizer REQUIRED CONFIG)
  endif()
  if(WITH_KTX)
    # The static KTX target links `zstd::libzstd`, which its package config does not import.
    set(zstd_DIR "${LIBDIR}/zstd/lib/cmake/zstd")
    find_package(zstd REQUIRED CONFIG)
    set(Ktx_DIR "${LIBDIR}/ktx/lib/cmake/ktx")
    find_package(Ktx REQUIRED CONFIG)
  endif()
  if(WITH_OPENTIMELINEIO)
    # The static OpenTimelineIO package finds its own dependencies.
    set(OpenTime_DIR "${LIBDIR}/opentimelineio/lib/cmake/opentime")
    set(Imath_DIR "${LIBDIR}/imath/lib/cmake/Imath")
    set(minizip-ng_DIR "${LIBDIR}/minizipng/lib/cmake/minizip")
    set(OpenTimelineIO_DIR "${LIBDIR}/opentimelineio/lib/cmake/opentimelineio")
    find_package(OpenTimelineIO REQUIRED CONFIG)
  endif()

  string(APPEND PLATFORM_CFLAGS " -pipe -funsigned-char -fno-strict-aliasing -ffp-contract=off")
  set(PLATFORM_LINKFLAGS "\
-fexceptions -framework Foundation -framework UIKit -framework CoreGraphics \
-framework Metal -framework MetalKit -framework QuartzCore -framework GameController \
-framework UniformTypeIdentifiers \
-framework Accelerate -framework AudioToolbox -framework CoreAudio \
-framework VideoToolbox -framework CoreMedia -framework CoreVideo \
-framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph -liconv"
  )
  if(WITH_PYTHON)
    string(APPEND PLATFORM_LINKFLAGS " -Wl,-rpath,@executable_path/Frameworks")
  endif()
  set(EXETYPE MACOSX_BUNDLE)
  set(CMAKE_C_FLAGS_DEBUG "-g")
  set(CMAKE_CXX_FLAGS_DEBUG "-g")
  set(CMAKE_C_FLAGS_RELEASE "-O2")
  set(CMAKE_CXX_FLAGS_RELEASE "-O2")
  string(APPEND CMAKE_CXX_FLAGS " -ftemplate-depth=1024")

  set(CMAKE_C_ARCHIVE_CREATE "<CMAKE_AR> Scr <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_CXX_ARCHIVE_CREATE "<CMAKE_AR> Scr <TARGET> <LINK_FLAGS> <OBJECTS>")
  if(NOT CMAKE_RANLIB MATCHES ".*llvm-ranlib$")
    set(CMAKE_C_ARCHIVE_FINISH "<CMAKE_RANLIB> -no_warning_for_no_symbols -c <TARGET>")
    set(CMAKE_CXX_ARCHIVE_FINISH "<CMAKE_RANLIB> -no_warning_for_no_symbols -c <TARGET>")
  endif()

  set(CMAKE_XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.blenderfoundation.blender.ios")
  message(STATUS "Using iOS dependency sysroot: ${LIBDIR}")
  message(STATUS "Using iOS host tools: ${IOS_HOST_TOOLS_DIR}")
  return()
endif()
