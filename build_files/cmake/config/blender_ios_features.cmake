# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Feature constraints shared by the canonical iOS target profiles and the
# native source-generator profile. Canonical targets start from blender_full;
# this file contains only concrete platform limits.

set(WITH_COMPILER_SIMD       OFF CACHE BOOL "" FORCE)
set(WITH_COMPILER_CCACHE     OFF CACHE BOOL "" FORCE)
set(WITH_GTESTS              OFF CACHE BOOL "" FORCE)
set(WITH_HEADLESS            OFF CACHE BOOL "" FORCE)
set(WITH_GHOST_SDL           OFF CACHE BOOL "" FORCE)
set(WITH_SDL                 OFF CACHE BOOL "" FORCE)
set(WITH_SDL_AUDIO           OFF CACHE BOOL "" FORCE)

# Audaspace's CoreAudio backend uses macOS Audio Hardware Abstraction Layer
# headers, including CoreAudioClock.h, which the iOS SDK does not provide.
# Blender audio remains available through the statically linked OpenAL backend.
set(WITH_COREAUDIO           OFF CACHE BOOL "" FORCE)

# UIKit and Metal replace these desktop platform integrations.
set(WITH_OPENGL_BACKEND      OFF CACHE BOOL "" FORCE)
set(WITH_VULKAN_BACKEND      OFF CACHE BOOL "" FORCE)
set(WITH_METAL_BACKEND       ON  CACHE BOOL "" FORCE)
set(WITH_INPUT_NDOF          OFF CACHE BOOL "" FORCE)
set(WITH_INPUT_IME           OFF CACHE BOOL "" FORCE)
set(WITH_XR_OPENXR           OFF CACHE BOOL "" FORCE)
set(WITH_BLENDER_THUMBNAILER OFF CACHE BOOL "" FORCE)

# Blender's Hydra engine directly uses OpenUSD Storm and HDX. OpenUSD 26.03
# still gates both libraries on OpenGL even when its Metal Hgi is available,
# while the iOS target intentionally has no OpenGL backend. USD import/export
# remains enabled.
set(WITH_HYDRA              OFF CACHE BOOL "" FORCE)

set(WITH_TBB_MALLOC_PROXY    OFF CACHE BOOL "" FORCE)
set(WITH_INSTALL_PORTABLE    ON  CACHE BOOL "" FORCE)

# OSL depends on an LLVM/JIT runtime that cannot execute under iOS platform
# policy. Cycles CPU, Metal, Embree, path guiding, and denoising remain enabled.
set(WITH_CYCLES_OSL          OFF CACHE BOOL "" FORCE)

# Blender 5.3 adds these optional libraries. They are not cross-built for iOS yet:
# Jolt has no users in 5.3, and OpenTimelineIO only backs VSE timeline import/export.
set(WITH_JOLT                OFF CACHE BOOL "" FORCE)
set(WITH_OPENTIMELINEIO      OFF CACHE BOOL "" FORCE)
