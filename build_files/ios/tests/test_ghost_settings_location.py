#!/usr/bin/env python3

"""The user settings folder is visible in Files (issue #62).

These tests build the Foundation-only settings location code for macOS and run
it against real temporary directories, so migration is exercised on an actual
file system rather than through mocks.
"""

from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
GHOST_INTERN = REPOSITORY / "intern" / "ghost" / "intern"
LOCATION_HEADER = GHOST_INTERN / "GHOST_IOSSettingsLocation.hh"
LOCATION_SOURCE = GHOST_INTERN / "GHOST_IOSSettingsLocation.mm"
PATHS_SOURCE = GHOST_INTERN / "GHOST_SystemPathsIOS.mm"
GHOST_CMAKE = REPOSITORY / "build_files" / "ios" / "cmake" / "ghost_ios.cmake"

DRIVER = textwrap.dedent(
    r"""
    #import <Foundation/Foundation.h>

    #include "GHOST_IOSSettingsLocation.hh"

    #include <cstdio>

    int main(int argc, char **argv)
    {
      @autoreleasepool {
        if (argc != 4) {
          return 2;
        }
        NSURL *documents = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSURL *legacy = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        NSURL *root = GHOST_IOSSettings_prepareRoot(documents, legacy, @(argv[3]));
        if (root == nil) {
          return 3;
        }
        std::printf("%s\n", root.path.fileSystemRepresentation);
      }
      return 0;
    }
    """
)


class GhostSettingsLocationTests(unittest.TestCase):
    executable: Path
    build_directory: tempfile.TemporaryDirectory

    @classmethod
    def setUpClass(cls) -> None:
        cls.build_directory = tempfile.TemporaryDirectory()
        build = Path(cls.build_directory.name)
        driver = build / "driver.mm"
        driver.write_text(DRIVER)
        cls.executable = build / "settings_location"
        result = subprocess.run(
            ["xcrun", "clang++", "-std=c++17", "-fno-objc-arc", "-Wall", "-Werror",
             "-I", str(GHOST_INTERN), str(driver), str(LOCATION_SOURCE),
             "-framework", "Foundation", "-o", str(cls.executable)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.build_directory.cleanup()

    def prepare(self, documents: Path, legacy: Path, version: str = "5.3") -> Path:
        result = subprocess.run(
            [str(self.executable), str(documents), str(legacy), version],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return Path(result.stdout.strip())

    def test_readme_follows_the_app_version_after_an_update(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            documents = Path(directory) / "Documents"
            legacy = Path(directory) / "Library" / "Application Support" / "Blender"
            documents.mkdir()
            self.prepare(documents, legacy, "5.2")
            readme = documents / "Settings" / "README.txt"
            self.assertIn("  5.2/config ", readme.read_text())

            self.prepare(documents, legacy, "5.3")

            self.assertIn("  5.3/config ", readme.read_text())
            self.assertNotIn("5.2", readme.read_text())

    def test_fresh_install_uses_a_visible_settings_folder_with_a_readme(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            documents = Path(directory) / "Documents"
            legacy = Path(directory) / "Library" / "Application Support" / "Blender"
            documents.mkdir()

            root = self.prepare(documents, legacy)

            self.assertEqual(root, documents / "Settings")
            self.assertTrue(root.is_dir())
            readme = (root / "README.txt").read_text()
            self.assertIn("  5.3/config ", readme)
            self.assertNotIn("5.2", readme)
            self.assertIn("Load", readme)
            self.assertIn("Resolution Scale", readme)
            self.assertFalse(legacy.exists())
            # Version folders are left to Blender so "Load Previous Settings" keeps working.
            self.assertEqual(sorted(p.name for p in root.iterdir()), ["README.txt"])

    def test_existing_settings_move_into_documents_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            documents = Path(directory) / "Documents"
            legacy = Path(directory) / "Library" / "Application Support" / "Blender"
            config = legacy / "5.2" / "config"
            config.mkdir(parents=True)
            documents.mkdir()
            (config / "userpref.blend").write_bytes(b"BLENDER-prefs")
            addon = legacy / "5.2" / "scripts" / "addons" / "tool.py"
            addon.parent.mkdir(parents=True)
            addon.write_text("bl_info = {}\n")

            root = self.prepare(documents, legacy)

            self.assertEqual(root, documents / "Settings")
            self.assertEqual((root / "5.2" / "config" / "userpref.blend").read_bytes(),
                             b"BLENDER-prefs")
            self.assertTrue((root / "5.2" / "scripts" / "addons" / "tool.py").is_file())
            self.assertFalse(legacy.exists())
            self.assertTrue((root / "README.txt").is_file())

            # Launching again leaves the migrated settings alone.
            (root / "5.2" / "config" / "userpref.blend").write_bytes(b"BLENDER-edited")
            self.assertEqual(self.prepare(documents, legacy), root)
            self.assertEqual((root / "5.2" / "config" / "userpref.blend").read_bytes(),
                             b"BLENDER-edited")

    def test_visible_settings_win_over_a_leftover_legacy_folder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            documents = Path(directory) / "Documents"
            legacy = Path(directory) / "Library" / "Application Support" / "Blender"
            (legacy / "5.2" / "config").mkdir(parents=True)
            (legacy / "5.2" / "config" / "userpref.blend").write_bytes(b"old")
            (documents / "Settings" / "5.2" / "config").mkdir(parents=True)
            (documents / "Settings" / "5.2" / "config" / "userpref.blend").write_bytes(b"new")

            root = self.prepare(documents, legacy)

            self.assertEqual(root, documents / "Settings")
            self.assertEqual((root / "5.2" / "config" / "userpref.blend").read_bytes(), b"new")
            # Nothing is deleted: the leftover copy stays where it was.
            self.assertEqual((legacy / "5.2" / "config" / "userpref.blend").read_bytes(), b"old")

    def test_keeps_using_the_old_folder_when_the_move_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            documents = Path(directory) / "Documents"
            legacy = Path(directory) / "Library" / "Application Support" / "Blender"
            (legacy / "5.2" / "config").mkdir(parents=True)
            (legacy / "5.2" / "config" / "userpref.blend").write_bytes(b"prefs")
            documents.mkdir()
            documents.chmod(0o500)
            try:
                root = self.prepare(documents, legacy)
            finally:
                documents.chmod(0o700)

            self.assertEqual(root, legacy)
            self.assertEqual((legacy / "5.2" / "config" / "userpref.blend").read_bytes(), b"prefs")


class GhostSettingsPathsWiringTests(unittest.TestCase):
    def test_user_dir_comes_from_the_settings_location(self) -> None:
        source = PATHS_SOURCE.read_text()
        user_dir = source[source.index("GHOST_SystemPathsCocoa::getUserDir") :]
        user_dir = user_dir[: user_dir.index("\n}\n")]
        self.assertIn("IOS_user_settings_root(versionstr)", user_dir)
        self.assertIn("GHOST_IOSSettings_prepareRoot", source)
        self.assertIn("dispatch_once", source)
        self.assertIn("NSDocumentDirectory", source)

    def test_settings_location_is_part_of_the_ghost_shim(self) -> None:
        cmake = GHOST_CMAKE.read_text()
        self.assertIn("intern/GHOST_IOSSettingsLocation.hh", cmake)
        self.assertIn("intern/GHOST_IOSSettingsLocation.mm", cmake)


if __name__ == "__main__":
    unittest.main()
