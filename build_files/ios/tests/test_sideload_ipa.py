# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


IOS_DIR = Path(__file__).resolve().parents[1]
if str(IOS_DIR) not in sys.path:
    sys.path.insert(0, str(IOS_DIR))

from package_sideload_ipa import RELEASE_APP_NAME, PackagingError, package_sideload_ipa


class SideloadIpaTests(unittest.TestCase):
    def make_bundle(self, root: Path, framework_count: int = 74) -> Path:
        bundle = root / "Blender.app"
        bundle.mkdir()
        with (bundle / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleDisplayName": "Blender",
                    "CFBundleExecutable": "Blender",
                    "CFBundleIdentifier": "org.blenderfoundation.blender.ios",
                    "CFBundleName": "Blender",
                    "CFBundlePackageType": "APPL",
                    "UIDeviceFamily": [1, 2],
                },
                handle,
            )
        source = root / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        subprocess.run(
            [
                "xcrun",
                "--sdk",
                "iphoneos",
                "clang",
                "-arch",
                "arm64",
                "-target",
                "arm64-apple-ios18.0",
                os.fspath(source),
                "-o",
                os.fspath(bundle / "Blender"),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        frameworks = bundle / "Frameworks"
        frameworks.mkdir()
        for index in range(framework_count):
            framework = frameworks / f"Fixture{index:02}.framework"
            framework.mkdir()
            (framework / "resource.txt").write_text("fixture\n")
        return bundle

    def test_packages_test_identity_under_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_bundle(root)
            output = root / "DevBlender.ipa"

            result = package_sideload_ipa(source, output, root / "staging")

            self.assertEqual(result.framework_count, 74)
            self.assertEqual(result.loose_library_count, 0)
            self.assertEqual(len(result.sha256), 64)
            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
                self.assertTrue(names)
                self.assertTrue(all(name.startswith("Payload/") for name in names))
                self.assertIn("Payload/Blender.app/Blender", names)
                plist = plistlib.loads(archive.read("Payload/Blender.app/Info.plist"))
            self.assertEqual(plist["CFBundleIdentifier"], "test.blenderfoundation.blender.ios")
            self.assertEqual(plist["CFBundleName"], "DevBlender")
            self.assertEqual(plist["CFBundleDisplayName"], "DevBlender")
            self.assertEqual(plist["CFBundleExecutable"], "Blender")

    def test_release_uses_the_public_app_name(self) -> None:
        # Releases keep the sideload bundle ID so installed copies update in place.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "3D-Modeling-Thingy.ipa"

            package_sideload_ipa(self.make_bundle(root), output, root / "staging",
                                 app_name=RELEASE_APP_NAME)

            with zipfile.ZipFile(output) as archive:
                plist = plistlib.loads(archive.read("Payload/Blender.app/Info.plist"))
            self.assertEqual(RELEASE_APP_NAME, "3D Modeling Thingy")
            self.assertEqual(plist["CFBundleIdentifier"], "test.blenderfoundation.blender.ios")
            self.assertEqual(plist["CFBundleName"], RELEASE_APP_NAME)
            self.assertEqual(plist["CFBundleDisplayName"], RELEASE_APP_NAME)
            self.assertEqual(plist["CFBundleExecutable"], "Blender")

    def test_rejects_loose_static_or_shared_libraries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_bundle(root)
            (source / "bad.so").write_bytes(b"not allowed")

            with self.assertRaisesRegex(PackagingError, "loose .so/.a"):
                package_sideload_ipa(source, root / "bad.ipa", root / "staging")

    def test_rejects_unexpected_framework_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_bundle(root, framework_count=73)

            with self.assertRaisesRegex(PackagingError, "expected 74 frameworks"):
                package_sideload_ipa(source, root / "bad.ipa", root / "staging")


if __name__ == "__main__":
    unittest.main()
