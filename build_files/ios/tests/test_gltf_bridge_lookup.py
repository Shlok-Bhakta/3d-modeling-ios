#!/usr/bin/env python3

"""Run the glTF add-on's bridge lookup against an iOS-shaped app bundle."""

from pathlib import Path
import importlib.util
import sys
import tempfile
import types
import unittest
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[3]
LIBRARY = REPOSITORY / "scripts" / "addons_core" / "io_scene_gltf2" / "io" / "com" / "library.py"


def load_library(binary_path: Path, local: Path):
    bpy = types.ModuleType("bpy")
    bpy.app = types.SimpleNamespace(binary_path=str(binary_path))
    bpy.utils = types.SimpleNamespace(
        resource_path=lambda kind: str(local) if kind == "LOCAL" else "")
    spec = importlib.util.spec_from_file_location("gltf_library_under_test", LIBRARY)
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, {"bpy": bpy}):
        spec.loader.exec_module(module)
    return module, bpy


class GltfBridgeLookupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)

    def lookup(self, platform: str, binary_path: Path, local: Path) -> Path | None:
        module, bpy = load_library(binary_path, local)
        with mock.patch.dict(sys.modules, {"bpy": bpy}), mock.patch.object(sys, "platform", platform):
            return module.dll_path("bf_intern_draco_bridge", "Draco")

    def test_ios_finds_bridges_in_the_app_frameworks(self) -> None:
        # Python 3.13 reports `ios` (PEP 730), not `darwin`, on iPadOS.
        app = self.root / "Blender.app"
        bridge = app / "Frameworks" / "libbf_intern_draco_bridge.dylib"
        bridge.parent.mkdir(parents=True)
        bridge.write_bytes(b"")
        self.assertEqual(self.lookup("ios", app / "Blender", app / "Assets" / "5.3"), bridge)

    def test_macos_keeps_the_bundled_lib_directory(self) -> None:
        resources = self.root / "Blender.app" / "Contents" / "Resources"
        binary = self.root / "Blender.app" / "Contents" / "MacOS" / "Blender"
        self.assertEqual(self.lookup("darwin", binary, resources / "5.3"),
                         resources / "lib" / "libbf_intern_draco_bridge.dylib")


if __name__ == "__main__":
    unittest.main()
