# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
CONFIG_DIRECTORY = REPOSITORY / "build_files" / "cmake" / "config"
METAL_DEVICE_SOURCE = REPOSITORY / "intern" / "cycles" / "device" / "metal" / "util.mm"

CYCLES_FEATURES = {
    "WITH_TBB": "ON",
    "WITH_TBB_MALLOC_PROXY": "OFF",
    "WITH_CYCLES": "ON",
    "WITH_CYCLES_DEVICE_METAL": "ON",
    "WITH_EMBREE": "ON",
    "WITH_CYCLES_OSL": "OFF",
    "WITH_CYCLES_PATH_GUIDING": "ON",
}


def read_boolean_settings(filename: str) -> dict[str, str]:
    contents = (CONFIG_DIRECTORY / filename).read_text()
    return dict(
        re.findall(
            r"set\((WITH_[A-Z0-9_]+)\s+(ON|OFF)(?:\s+CACHE\s+BOOL\s+\"\"\s+FORCE)?\)",
            contents,
        )
    )


class CyclesProfileTests(unittest.TestCase):
    def test_device_and_simulator_cycles_profiles_match(self) -> None:
        simulator = read_boolean_settings("blender_ios_sim.cmake")
        device = read_boolean_settings("blender_ios_device.cmake")

        for feature in CYCLES_FEATURES:
            self.assertEqual(simulator.get(feature), device.get(feature), feature)

    def test_cpu_and_metal_cycles_profile_is_explicit(self) -> None:
        for filename in ("blender_ios_sim.cmake", "blender_ios_device.cmake"):
            with self.subTest(filename=filename):
                settings = read_boolean_settings(filename)
                for feature, expected in CYCLES_FEATURES.items():
                    self.assertEqual(settings.get(feature), expected, feature)

    def test_ios_metal_requires_tier_two_argument_buffers(self) -> None:
        source = METAL_DEVICE_SOURCE.read_text()
        self.assertIn(
            "usable = [device argumentBuffersSupport] == MTLArgumentBuffersTier2;",
            source,
        )


if __name__ == "__main__":
    unittest.main()
