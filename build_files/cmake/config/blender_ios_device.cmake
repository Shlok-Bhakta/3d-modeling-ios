# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Canonical physical iPhone/iPad profile. Start from the full Blender feature
# set, then apply only documented iOS platform constraints.
include("${CMAKE_CURRENT_LIST_DIR}/blender_full.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/blender_ios_features.cmake")

set(APPLE_TARGET_DEVICE       ios CACHE STRING "" FORCE)
set(WITH_APPLE_CROSSPLATFORM ON  CACHE BOOL   "" FORCE)
set(BLENDER_PLATFORM_XCODE_CMAKE
  "${CMAKE_SOURCE_DIR}/build_files/ios/cmake/platform_ios_xcode.cmake"
  CACHE FILEPATH "iOS Xcode platform setup" FORCE)

set(WITH_PYTHON         ON CACHE BOOL "" FORCE)
set(WITH_PYTHON_INSTALL ON CACHE BOOL "" FORCE)

set(WITH_PYTHON_INSTALL_NUMPY     ON CACHE BOOL "" FORCE)
set(WITH_PYTHON_INSTALL_ZSTANDARD ON CACHE BOOL "" FORCE)

# Required by the Subdivision Surface and Multiresolution modifiers. The iOS
# dependency sysroot provides the portable CPU evaluator and Metal support.
set(WITH_OPENSUBDIV ON CACHE BOOL "" FORCE)

# Keep the portable CPU renderer as the fallback while compiling the native
# Metal device. TBB is static in the iOS dependency sysroot.
set(WITH_TBB                 ON  CACHE BOOL "" FORCE)
set(WITH_TBB_MALLOC_PROXY    OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES              ON  CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_METAL ON  CACHE BOOL "" FORCE)
set(WITH_EMBREE              ON  CACHE BOOL "" FORCE)
set(WITH_CYCLES_OSL          OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_PATH_GUIDING ON  CACHE BOOL "" FORCE)

# The artifact is handed to the owner without an identity, provisioning
# profile, signer entitlements, or bundle signature.
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO" CACHE STRING "" FORCE)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO" CACHE STRING "" FORCE)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Manual" CACHE STRING "" FORCE)
