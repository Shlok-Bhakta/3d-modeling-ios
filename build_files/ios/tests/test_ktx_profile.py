# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Source checks for the KTX glTF bridge on iOS.

`build_files/ios/simulator_interchange.py --check ktx` covers the behavior.
"""

from pathlib import Path
import unittest

from build_files.ios.package_gltf_bridges import BRIDGE_NAMES


REPOSITORY = Path(__file__).resolve().parents[3]
IOS_DEPS = REPOSITORY / "build_files" / "ios" / "build_environment"


class KtxProfileTests(unittest.TestCase):
    def test_ios_builds_ktx_statically_with_the_ios_patch(self) -> None:
        recipe = (IOS_DEPS / "cmake" / "ktx.cmake").read_text()
        self.assertIn("-DBUILD_SHARED_LIBS=OFF", recipe)
        self.assertIn("-Dzstd_DIR=${LIBDIR}/zstd/lib/cmake/zstd", recipe)
        self.assertIn("${IOS_PATCH_DIR}/ktx_ios_static.diff", recipe)
        self.assertIn('harvest(external_ktx ktx/lib ktx/lib "*.a")', recipe)

    def test_ios_patch_keeps_a_plain_static_library(self) -> None:
        patch = (IOS_DEPS / "patches" / "ktx_ios_static.diff").read_text()
        self.assertIn("+    if(APPLE_LOCKED_OS AND NOT ${library_type} STREQUAL STATIC)", patch)
        self.assertIn("+if (APPLE_LOCKED_OS AND BUILD_SHARED_LIBS)", patch)
        self.assertIn("+            COMMAND xcrun libtool -static", patch)

    def test_app_finds_ktx_and_packages_its_bridge(self) -> None:
        features = (REPOSITORY / "build_files" / "cmake" / "config" /
                    "blender_ios_features.cmake").read_text()
        self.assertNotIn("set(WITH_KTX", features)
        platform = (REPOSITORY / "build_files" / "ios" / "cmake" / "platform_ios.cmake").read_text()
        zstd = platform.index("find_package(zstd REQUIRED CONFIG)")
        self.assertLess(zstd, platform.index("find_package(Ktx REQUIRED CONFIG)"))
        self.assertIn("libbf_intern_ktx_bridge.dylib", BRIDGE_NAMES)

    def test_ci_builds_ktx(self) -> None:
        workflow = (REPOSITORY / ".github" / "workflows" / "ios-pr-preview.yml").read_text()
        self.assertIn(";USD;KTX\"", workflow)
        self.assertIn("external_ktx \\", workflow)


if __name__ == "__main__":
    unittest.main()
