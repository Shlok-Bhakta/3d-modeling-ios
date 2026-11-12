#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Create the audited DevBlender sideload IPA used by PR previews."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from typing import Sequence
import zipfile

from audit import audit_bundle
from package_unsigned_ipa import (
    archive_bundle,
    embedded_binary_findings,
    metadata_findings,
)


SIDELOAD_BUNDLE_ID = "test.blenderfoundation.blender.ios"
SIDELOAD_APP_NAME = "DevBlender"
# Public releases keep the sideload bundle ID, so installed copies update in place.
RELEASE_APP_NAME = "3D Modeling Thingy"
EXPECTED_FRAMEWORK_COUNT = 74


class PackagingError(RuntimeError):
    pass


@dataclass(frozen=True)
class PackageResult:
    ipa: str
    sha256: str
    framework_count: int
    loose_library_count: int
    zip_entry_count: int


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_source_bundle(bundle: Path, expected_framework_count: int) -> None:
    findings = audit_bundle(bundle, "device-unsigned", ())
    findings.extend(metadata_findings(bundle))
    plist_path = bundle / "Info.plist"
    executable_name = ""
    try:
        with plist_path.open("rb") as handle:
            executable_name = str(plistlib.load(handle).get("CFBundleExecutable", ""))
    except (OSError, plistlib.InvalidFileException):
        pass
    if executable_name:
        findings.extend(embedded_binary_findings(bundle, bundle / executable_name))
    if findings:
        detail = "; ".join(
            f"{item.code}: {item.message} at {item.path}" for item in findings
        )
        raise PackagingError(f"source bundle audit failed: {detail}")

    loose_libraries = sorted(
        path for path in bundle.rglob("*") if path.is_file() and path.suffix in {".a", ".so"}
    )
    if loose_libraries:
        raise PackagingError(
            f"expected 0 loose .so/.a files, found {len(loose_libraries)}: "
            f"{loose_libraries[0]}"
        )

    frameworks_root = bundle / "Frameworks"
    frameworks = (
        sorted(path for path in frameworks_root.glob("*.framework") if path.is_dir())
        if frameworks_root.is_dir()
        else []
    )
    if len(frameworks) != expected_framework_count:
        raise PackagingError(
            f"expected {expected_framework_count} frameworks, found {len(frameworks)}"
        )


def patch_sideload_identity(bundle: Path, app_name: str) -> None:
    plist_path = bundle / "Info.plist"
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    plist["CFBundleIdentifier"] = SIDELOAD_BUNDLE_ID
    plist["CFBundleName"] = app_name
    plist["CFBundleDisplayName"] = app_name
    if plist.get("CFBundleExecutable") != "Blender":
        raise PackagingError("CFBundleExecutable must remain Blender")
    with plist_path.open("wb") as handle:
        plistlib.dump(plist, handle, sort_keys=True)


def package_sideload_ipa(
    source_bundle: Path,
    output: Path,
    staging_root: Path,
    expected_framework_count: int = EXPECTED_FRAMEWORK_COUNT,
    app_name: str = SIDELOAD_APP_NAME,
) -> PackageResult:
    source_bundle = source_bundle.resolve()
    output = output.resolve()
    staging_root = staging_root.resolve()
    validate_source_bundle(source_bundle, expected_framework_count)

    staged_bundle = staging_root / "Blender.app"
    if staging_root.exists():
        shutil.rmtree(staging_root)
    staging_root.mkdir(parents=True)
    shutil.copytree(source_bundle, staged_bundle, symlinks=True)
    patch_sideload_identity(staged_bundle, app_name)
    archive_bundle(staged_bundle, output)

    with zipfile.ZipFile(output) as archive:
        names = archive.namelist()
        if not names or any(not name.startswith("Payload/") for name in names):
            raise PackagingError("every IPA entry must start with Payload/")
        corrupt_entry = archive.testzip()
        if corrupt_entry:
            raise PackagingError(f"ZIP CRC failed for {corrupt_entry}")
    unzip_result = subprocess.run(
        ["unzip", "-t", str(output)], check=False, capture_output=True, text=True
    )
    if unzip_result.returncode != 0:
        raise PackagingError(f"unzip -t failed: {unzip_result.stdout}{unzip_result.stderr}")

    return PackageResult(
        ipa=str(output),
        sha256=file_sha256(output),
        framework_count=expected_framework_count,
        loose_library_count=0,
        zip_entry_count=len(names),
    )


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--staging-root", required=True, type=Path)
    parser.add_argument("--release", action="store_true",
                        help=f"name the app {RELEASE_APP_NAME!r} instead of {SIDELOAD_APP_NAME!r}")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        result = package_sideload_ipa(
            arguments.bundle,
            arguments.output,
            arguments.staging_root,
            app_name=RELEASE_APP_NAME if arguments.release else SIDELOAD_APP_NAME,
        )
    except PackagingError as ex:
        print(json.dumps({"ok": False, "error": str(ex)}, indent=2))
        return 1
    print(json.dumps({"ok": True, **asdict(result)}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
