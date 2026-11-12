# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

from pathlib import Path
import importlib.util
import sys
import tempfile
import types
import unittest
from unittest import mock

from build_files.ios.package_gltf_bridges import BRIDGE_NAMES, package_bridges


REPOSITORY = Path(__file__).resolve().parents[3]
GLTF_LIBRARY = (
    REPOSITORY
    / "scripts/addons_core/io_scene_gltf2/io/com/library.py"
)


class PackageGltfBridgesTests(unittest.TestCase):
    def test_relocates_bridges_and_keeps_addon_links(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "Blender.app"
            addon = bundle / "Assets/5.2/scripts/addons_core/io_scene_gltf2"
            addon.mkdir(parents=True)
            for index, name in enumerate(BRIDGE_NAMES):
                (addon / name).write_bytes(f"bridge-{index}".encode())

            relocated = package_bridges(bundle, addon)

            self.assertEqual(len(relocated), len(BRIDGE_NAMES))
            for index, name in enumerate(BRIDGE_NAMES):
                destination = bundle / "Frameworks" / name
                self.assertFalse((addon / name).exists())
                self.assertEqual(destination.read_bytes(), f"bridge-{index}".encode())

            self.assertEqual(package_bridges(bundle, addon), [])

    def test_darwin_loader_falls_back_to_app_frameworks(self) -> None:
        spec = importlib.util.spec_from_file_location("gltf_library_fixture", GLTF_LIBRARY)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        library = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(library)

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Blender.app"
            addon = bundle / "Assets/5.2/scripts/addons_core/io_scene_gltf2"
            addon.mkdir(parents=True)
            bridge = bundle / "Frameworks/libfixture.dylib"
            bridge.parent.mkdir()
            bridge.write_bytes(b"fixture")
            modules = {
                "bpy": types.SimpleNamespace(
                    app=types.SimpleNamespace(binary_path=str(bundle / "Blender"))
                ),
                "io_scene_gltf2": types.SimpleNamespace(__file__=str(addon / "__init__.py")),
            }

            with mock.patch.dict(sys.modules, modules), mock.patch.object(
                sys, "platform", "darwin"
            ):
                path = library.dll_path("fixture", "Fixture")

            self.assertEqual(path, bridge)


if __name__ == "__main__":
    unittest.main()
