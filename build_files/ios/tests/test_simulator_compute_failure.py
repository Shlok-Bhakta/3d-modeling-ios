# SPDX-FileCopyrightText: 2026 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later

import importlib.util
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "simulator_compute_failure", ROOT / "build_files/ios/simulator_compute_failure.py")
regression = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(regression)


class ComputeFailureOutcomeTests(unittest.TestCase):
    def setUp(self):
        self.state = dict(failed_pipelines=2, recovered_pipelines=1,
                          completed_renders=3, post_render_ticks=3)

    def test_repeated_rejection_and_recovery_pass(self):
        regression.validate_state(self.state)

    def test_unexercised_failure_does_not_pass(self):
        self.state['failed_pipelines'] = 0
        with self.assertRaises(regression.ComputeFailure):
            regression.validate_state(self.state)

    def test_render_that_never_returned_does_not_pass(self):
        self.state['completed_renders'] = 1
        with self.assertRaises(regression.ComputeFailure):
            regression.validate_state(self.state)

    def test_frozen_main_loop_does_not_pass(self):
        self.state['post_render_ticks'] = 0
        with self.assertRaises(regression.ComputeFailure):
            regression.validate_state(self.state)

    def test_pipeline_that_never_recovers_does_not_pass(self):
        self.state['recovered_pipelines'] = 0
        with self.assertRaises(regression.ComputeFailure):
            regression.validate_state(self.state)

    def test_script_error_does_not_pass(self):
        self.state['error'] = 'render failed'
        with self.assertRaisesRegex(regression.ComputeFailure, 'render failed'):
            regression.validate_state(self.state)

    @unittest.skipUnless(platform.system() == 'Darwin', 'requires an iOS Simulator SDK')
    def test_fault_fixture_compiles_for_simulator(self):
        with tempfile.TemporaryDirectory(prefix='metal-compute-fixture-') as directory:
            result = subprocess.run([
                'xcrun', '--sdk', 'iphonesimulator', 'clang++', '-std=c++17', '-dynamiclib',
                '-target', 'arm64-apple-ios18.0-simulator', '-framework', 'Foundation',
                '-framework', 'Metal',
                str(ROOT / 'build_files/ios/metal_compute_failure_fixture.mm'),
                '-o', str(Path(directory) / 'fixture.dylib'),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
