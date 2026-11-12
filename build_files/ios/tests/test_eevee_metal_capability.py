# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
LIGHT_ITER_SOURCE = (
    REPOSITORY
    / "source"
    / "blender"
    / "draw"
    / "engines"
    / "eevee"
    / "shaders"
    / "eevee_light_iter.bsl.hh"
)
CAPABILITIES_HEADER = (
    REPOSITORY / "source" / "blender" / "gpu" / "metal" / "mtl_capabilities.hh"
)
BACKEND_SOURCE = REPOSITORY / "source" / "blender" / "gpu" / "metal" / "mtl_backend.mm"
SHADER_SOURCE = REPOSITORY / "source" / "blender" / "gpu" / "metal" / "mtl_shader.mm"


class EeveeMetalCapabilityTests(unittest.TestCase):
    def test_simdgroup_reductions_are_capability_gated(self) -> None:
        light_iter = LIGHT_ITER_SOURCE.read_text()
        capability = CAPABILITIES_HEADER.read_text()
        backend = BACKEND_SOURCE.read_text()
        shader = SHADER_SOURCE.read_text()

        guard = "#if defined(GPU_METAL) && defined(MTL_SUPPORTS_SIMDGROUP_REDUCTION)"
        reductions = 0
        enclosing_condition = None
        for line in light_iter.splitlines():
            stripped = line.strip()
            if stripped.startswith("#if"):
                enclosing_condition = stripped
            elif "simd_" in stripped:
                reductions += 1
                self.assertEqual(enclosing_condition, guard, stripped)
        self.assertGreaterEqual(reductions, 4)
        self.assertIn("bool supports_simdgroup_reduction = false;", capability)
        self.assertIn("capabilities.supports_simdgroup_reduction =", backend)
        self.assertIn("capabilities().supports_simdgroup_reduction", shader)
        self.assertIn('"#define MTL_SUPPORTS_SIMDGROUP_REDUCTION\\n"', shader)


if __name__ == "__main__":
    unittest.main()
