# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
CONFIG_DIRECTORY = REPOSITORY / "build_files" / "cmake" / "config"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "ios-pr-preview.yml"
IOS_DEPENDENCY_PLATFORM = (
    REPOSITORY / "build_files" / "ios" / "build_environment" / "cmake" / "ios_platform.cmake"
)
IOS_FEATURES = CONFIG_DIRECTORY / "blender_ios_features.cmake"
APPLE_PLATFORM = (
    REPOSITORY / "build_files" / "ios" / "cmake" / "platform_ios.cmake"
)
USD_RECIPE = REPOSITORY / "build_files" / "ios" / "build_environment" / "cmake" / "usd.cmake"
USD_NO_GL_PATCH = (
    REPOSITORY
    / "build_files"
    / "ios"
    / "build_environment"
    / "patches"
    / "usd_no_storm_without_gl.diff"
)
FFMPEG_RECIPE = (
    REPOSITORY / "build_files" / "ios" / "build_environment" / "cmake" / "ffmpeg.cmake"
)
FLAC_RECIPE = (
    REPOSITORY / "build_files" / "ios" / "build_environment" / "cmake" / "flac.cmake"
)
MATERIALX_RECIPE = (
    REPOSITORY
    / "build_files"
    / "ios"
    / "build_environment"
    / "cmake"
    / "materialx.cmake"
)
DRACO_IOS_PATCH = (
    REPOSITORY
    / "build_files"
    / "ios"
    / "build_environment"
    / "patches"
    / "draco_no_ios_tools.diff"
)
MESHOPTIMIZER_RECIPE = (
    REPOSITORY
    / "build_files"
    / "ios"
    / "build_environment"
    / "cmake"
    / "meshoptimizer.cmake"
)
MSGFMT_CMAKE = (
    REPOSITORY
    / "source"
    / "blender"
    / "blentranslation"
    / "msgfmt"
    / "CMakeLists.txt"
)
APPLE_MESSAGES = (
    REPOSITORY
    / "source"
    / "blender"
    / "blentranslation"
    / "intern"
    / "messages_apple.mm"
)
QUADRIFLOW_LOCAL_SAT = REPOSITORY / "extern" / "quadriflow" / "src" / "localsat.cpp"
QUADRIFLOW_HIERARCHY = REPOSITORY / "extern" / "quadriflow" / "src" / "hierarchy.cpp"
USD_CMAKE = REPOSITORY / "source" / "blender" / "io" / "usd" / "CMakeLists.txt"
USD_HOOK_STUB = (
    REPOSITORY / "source" / "blender" / "io" / "usd" / "intern" / "usd_hook_stub.cc"
)


class FullProfileTests(unittest.TestCase):
    def test_canonical_profiles_start_from_blender_full(self) -> None:
        for filename in ("blender_ios_sim.cmake", "blender_ios_device.cmake"):
            with self.subTest(filename=filename):
                profile = (CONFIG_DIRECTORY / filename).read_text()
                self.assertIn(
                    'include("${CMAKE_CURRENT_LIST_DIR}/blender_full.cmake")',
                    profile,
                )
                self.assertNotIn("blender_ios_sim_minimal.cmake", profile)
                self.assertNotIn("blender_ios_device_minimal.cmake", profile)
                self.assertNotIn("blender_lite.cmake", profile)

    def test_packaged_executable_is_audited_for_opensubdiv(self) -> None:
        workflow = WORKFLOW.read_text()
        self.assertIn("audit_build_features.py", workflow)
        self.assertIn('"$APP_BUILD/bin/Blender.app/Blender"', workflow)
        self.assertIn("--require-opensubdiv", workflow)

    def test_ios_dependencies_accept_supported_legacy_cmake_projects(self) -> None:
        platform = IOS_DEPENDENCY_PLATFORM.read_text()
        self.assertIn("-DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5", platform)

    def test_ios_profile_keeps_full_features_with_only_platform_cuts(self) -> None:
        features = IOS_FEATURES.read_text()
        platform = APPLE_PLATFORM.read_text()
        self.assertNotIn("set(WITH_OPENSUBDIV", features)
        self.assertNotIn("set(WITH_EMBREE", features)
        self.assertNotIn("set(WITH_CYCLES_PATH_GUIDING", features)
        self.assertIn("set(WITH_CYCLES_OSL", features)
        self.assertIn("set(WITH_HYDRA", features)
        self.assertIn("set(WITH_COREAUDIO", features)
        self.assertNotIn("set(WITH_OPENAL", features)
        self.assertIn('set(OPENAL_INCLUDE_DIR "${LIBDIR}/openal/include/AL")', platform)
        self.assertIn('set(WEBP_ROOT_DIR "${LIBDIR}/webp")', platform)
        self.assertIn("find_package(WebP REQUIRED)", platform)
        self.assertIn("libOpenImageDenoise_device_metal.a", platform)
        self.assertIn("OPENIMAGEDENOISE_COMMON_LIBRARY", platform)
        self.assertIn("-framework MetalPerformanceShadersGraph", platform)
        self.assertIn("-liconv", platform)
        self.assertIn("USD import/export", features)

        for filename in ("blender_ios_sim.cmake", "blender_ios_device.cmake"):
            with self.subTest(filename=filename):
                profile = (CONFIG_DIRECTORY / filename).read_text()
                self.assertIn("set(WITH_EMBREE              ON", profile)
                self.assertIn("set(WITH_CYCLES_PATH_GUIDING ON", profile)

    def test_quadriflow_keeps_remeshing_without_ios_subprocesses(self) -> None:
        local_sat = QUADRIFLOW_LOCAL_SAT.read_text()
        hierarchy = QUADRIFLOW_HIERARCHY.read_text()
        platform = APPLE_PLATFORM.read_text()
        self.assertIn("QUADRIFLOW_SUBPROCESS_SUPPORT=0", platform)
        self.assertIn("QUADRIFLOW_SUBPROCESS_SUPPORT", local_sat)
        self.assertIn("return SolverStatus::Unsat;", local_sat)
        self.assertIn("QUADRIFLOW_SUBPROCESS_SUPPORT", hierarchy)
        self.assertIn("return 0;", hierarchy)

    def test_usd_uses_static_apple_embedded_metal_profile(self) -> None:
        recipe = USD_RECIPE.read_text()
        self.assertIn("set(USD_BUILD_SHARED_LIBS OFF)", recipe)
        self.assertIn("-DPXR_BUILD_APPLE_FRAMEWORK=OFF", recipe)
        self.assertIn("set(USD_ENABLE_METAL_SUPPORT ON)", recipe)
        self.assertIn("set(USD_ENABLE_GL_SUPPORT OFF)", recipe)
        self.assertIn("set(USD_ENABLE_PYTHON_SUPPORT OFF)", recipe)
        self.assertIn("usd_no_storm_without_gl.diff", recipe)
        no_gl_patch = USD_NO_GL_PATCH.read_text()
        self.assertIn("if (NOT TARGET hdSt)", no_gl_patch)
        self.assertIn("if (NOT TARGET hdx)", no_gl_patch)
        self.assertIn("if (NOT TARGET usdImagingGL)", no_gl_patch)
        # USD 26.08 links hgiInterop's garch dependency even when garch is not built.
        self.assertIn("+++ b/pxr/imaging/hgiInterop/CMakeLists.txt", no_gl_patch)
        self.assertIn("-list(APPEND optionalLibraries garch)", no_gl_patch)
        self.assertIn("+    list(APPEND optionalLibraries garch)", no_gl_patch)
        usd_cmake = USD_CMAKE.read_text()
        self.assertIn("BLENDER_PLATFORM_USD_HOOK_SOURCE", usd_cmake)
        self.assertIn("intern/usd_hook_stub.cc", APPLE_PLATFORM.read_text())
        self.assertIn("return false;", USD_HOOK_STUB.read_text())

    def test_ffmpeg_keeps_ios_media_with_native_apple_acceleration(self) -> None:
        recipe = FFMPEG_RECIPE.read_text()
        self.assertIn("--enable-videotoolbox", recipe)
        self.assertIn("--enable-audiotoolbox", recipe)
        self.assertIn("--enable-libvpx", recipe)
        self.assertIn("--enable-libtheora", recipe)
        self.assertIn("--enable-libvorbis", recipe)

        platform = APPLE_PLATFORM.read_text()
        self.assertIn('set(FFMPEG_ROOT_DIR "${LIBDIR}/ffmpeg")', platform)
        self.assertIn("find_package(FFmpeg REQUIRED)", platform)
        self.assertIn('set(USD_ROOT_DIR "${LIBDIR}/usd")', platform)
        self.assertIn("find_package(USD REQUIRED)", platform)

    def test_meshoptimizer_bridge_is_self_contained_on_ios(self) -> None:
        recipe = MESHOPTIMIZER_RECIPE.read_text()
        self.assertIn("if(IOS)", recipe)
        self.assertIn("-DMESHOPT_BUILD_SHARED_LIBS=OFF", recipe)

    def test_flac_ios_build_uses_cmake_without_versioned_automake_tools(self) -> None:
        recipe = FLAC_RECIPE.read_text()
        self.assertIn('CMAKE_GENERATOR "Ninja"', recipe)
        self.assertNotIn("${CONFIGURE_COMMAND}", recipe)
        self.assertIn("if(WITH_APPLE_CROSSPLATFORM)", recipe)
        self.assertIn("-DOGG_LIBRARY=${LIBDIR}/ogg/lib/libogg.a", recipe)

    def test_materialx_ios_omits_disabled_python_dependencies(self) -> None:
        recipe = MATERIALX_RECIPE.read_text()
        self.assertIn("-DMATERIALX_BUILD_PYTHON=OFF", recipe)
        self.assertIn(
            "add_dependencies(external_materialx external_python external_pybind11)",
            recipe,
        )
        self.assertIn("if(NOT WITH_APPLE_CROSSPLATFORM)", recipe)

    def test_draco_ios_omits_tools_from_build_and_install(self) -> None:
        patch = DRACO_IOS_PATCH.read_text()
        self.assertGreaterEqual(
            patch.count('if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")'),
            2,
        )
        self.assertIn("install(TARGETS draco_decoder", patch)
        self.assertIn("install(TARGETS draco_encoder", patch)

    def test_localization_uses_a_native_msgfmt_during_cross_compile(self) -> None:
        platform = APPLE_PLATFORM.read_text()
        self.assertIn("datatoc msgfmt shader_tool", platform)
        self.assertIn("if(NOT TARGET msgfmt)", MSGFMT_CMAKE.read_text())
        messages = APPLE_MESSAGES.read_text()
        self.assertIn("<Foundation/Foundation.h>", messages)
        self.assertNotIn("<Cocoa/Cocoa.h>", messages)


if __name__ == "__main__":
    unittest.main()
