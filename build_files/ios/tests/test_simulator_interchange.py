#!/usr/bin/env python3

"""Unit coverage for the pure parts of the interchange simulator harness."""

from pathlib import Path
import ast
import copy
import importlib.util
import sys
import unittest


IOS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("simulator_interchange", IOS / "simulator_interchange.py")
harness = importlib.util.module_from_spec(spec)
sys.modules["simulator_interchange"] = harness
spec.loader.exec_module(harness)


def passing_bridges_report() -> dict:
    codec = {"export_result": ["FINISHED"], "extension_used": True,
             "import_result": ["FINISHED"], "imported_triangles": 128}
    return {
        "check": "gltf-bridges",
        "errors": [],
        "lookup": {
            "bf_intern_draco_bridge": {"path": "/app/Frameworks/libbf_intern_draco_bridge.dylib",
                                       "found": True},
            "bf_intern_meshopt_bridge": {"path": "/app/Frameworks/libbf_intern_meshopt_bridge.dylib",
                                         "found": True},
        },
        "expected_triangles": 128,
        "codecs": {"draco": dict(codec), "meshopt": dict(codec)},
    }


def passing_ktx_report() -> dict:
    return {
        "check": "ktx",
        "errors": [],
        "bridge": {"path": "/app/Frameworks/libbf_intern_ktx_bridge.dylib", "exists": True},
        "export": {"result": ["FINISHED"], "basisu_used": True,
                   "ktx2_files": ["source.ktx2"], "magic_ok": True},
        "import": {"result": ["FINISHED"], "images": [{"name": "source.ktx2", "size": [16, 16]}],
                   "max_error": 0.04},
    }


class InterchangeHarnessTests(unittest.TestCase):
    def test_every_check_builds_valid_python(self) -> None:
        for check in harness.CHECKS:
            with self.subTest(check=check):
                ast.parse(harness.python_expr(check))
                self.assertIn(check, harness.VALIDATORS)

    def test_a_clean_bridges_run_passes(self) -> None:
        self.assertEqual(harness.validate(passing_bridges_report(), "Read prefs\n"), [])

    def test_unreachable_bridges_fail(self) -> None:
        # What the 5.3 sync build produced: Python reports `ios`, so the add-on looked for
        # Linux `.so` files and exported without compression.
        report = copy.deepcopy(passing_bridges_report())
        for entry in report["lookup"].values():
            entry["found"] = False
            entry["path"] = "/app/Assets/lib/" + Path(entry["path"]).stem + ".so"
        for codec in report["codecs"].values():
            codec["extension_used"] = False
        failures = harness.validate(report, "")
        self.assertEqual(len(failures), 4, failures)
        self.assertIn("libbf_intern_draco_bridge.so", failures[0])
        self.assertIn("did not use KHR_draco_mesh_compression", failures[2])

    def test_missing_bridges_and_geometry_loss_fail(self) -> None:
        report = copy.deepcopy(passing_bridges_report())
        report["lookup"] = {}
        report["codecs"]["meshopt"]["imported_triangles"] = 0
        del report["codecs"]["draco"]
        self.assertEqual(harness.validate(report, ""), [
            "no glTF bridge is packaged in Frameworks",
            "draco export did not run",
            "meshopt import has 0 triangles, expected 128",
        ])

    def test_a_clean_ktx_run_passes(self) -> None:
        self.assertEqual(harness.validate(passing_ktx_report(), "Read prefs\n"), [])

    def test_ktx_without_the_bridge_fails(self) -> None:
        # What the build produces without KTX: the bridge is not built, so the
        # exporter skips KTX2 and there is nothing to decode on import.
        report = passing_ktx_report()
        report["bridge"]["exists"] = False
        report["export"].update(basisu_used=False, ktx2_files=[], magic_ok=False)
        report["import"].update(images=[], max_error=None)
        failures = harness.validate(report, "")
        self.assertEqual(len(failures), 4, failures)
        self.assertIn("KTX bridge is missing", failures[0])

    def test_ktx_decoding_errors_are_reported(self) -> None:
        report = passing_ktx_report()
        report["import"]["max_error"] = 0.9
        self.assertEqual(harness.validate(report, ""), ["decoded KTX2 pixels differ by 0.900"])
        report["import"]["max_error"] = None
        self.assertIn("wrong size", harness.validate(report, "")[0])

    def test_harness_errors_and_tracebacks_fail(self) -> None:
        report = passing_bridges_report()
        report["errors"] = ["Traceback ...\nKeyError: 'bridge_grid'\n"]
        failures = harness.validate(report, "Traceback (most recent call last):\n")
        self.assertEqual(failures, ["harness error: KeyError: 'bridge_grid'",
                                    "app log contains a Python traceback"])


if __name__ == "__main__":
    unittest.main()
