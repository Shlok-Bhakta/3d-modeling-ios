# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Source checks for OpenTimelineIO on iOS.

`build_files/ios/simulator_interchange.py --check otio` covers the behavior.
"""

from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]


class OpenTimelineIOProfileTests(unittest.TestCase):
    def test_ios_builds_only_the_static_cpp_library(self) -> None:
        recipe = (REPOSITORY / "build_files" / "ios" / "build_environment" / "cmake" /
                  "opentimelineio.cmake").read_text()
        for option in ("-DOTIO_SHARED_LIBS=OFF", "-DOTIO_PYTHON_INSTALL=OFF",
                       "-DOTIO_FIND_PYBIND11=OFF", "-DOTIO_INSTALL_PYTHON_MODULES=OFF",
                       "-DOTIO_INSTALL_COMMANDLINE_TOOLS=OFF",
                       "-Dminizip-ng_DIR=${LIBDIR}/minizipng/lib/cmake/minizip",
                       # Hidden RTTI breaks OpenTimelineIO's `std::any` type checks in Blender.
                       "-DCMAKE_CXX_VISIBILITY_PRESET=default"):
            self.assertIn(option, recipe)
        self.assertIn("add_dependencies(external_opentimelineio external_pybind11)", recipe)

    def test_app_finds_opentimelineio(self) -> None:
        features = (REPOSITORY / "build_files" / "cmake" / "config" /
                    "blender_ios_features.cmake").read_text()
        self.assertNotIn("set(WITH_OPENTIMELINEIO", features)
        platform = (REPOSITORY / "build_files" / "ios" / "cmake" / "platform_ios.cmake").read_text()
        self.assertLess(platform.index('set(OpenTime_DIR "'),
                        platform.index("find_package(OpenTimelineIO REQUIRED CONFIG)"))

    def test_ci_builds_opentimelineio(self) -> None:
        workflow = (REPOSITORY / ".github" / "workflows" / "ios-pr-preview.yml").read_text()
        self.assertIn(";KTX;OPENTIMELINEIO;RAPIDJSON\"", workflow)
        self.assertIn("external_opentimelineio \\", workflow)


if __name__ == "__main__":
    unittest.main()
