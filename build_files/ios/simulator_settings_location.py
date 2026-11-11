#!/usr/bin/env python3

"""Check where the app keeps Blender's user settings, on a real simulator.

Each case installs the app on a fresh simulator container, seeds the folders a
user would have, launches Blender normally (not with --factory-startup, which
ignores user settings), and reads back what Blender resolved:

* migrate: settings in the old hidden Application Support folder move to
  Documents/Settings, and Blender runs a user startup script from there.
* fresh: a new install gets Documents/Settings with a README.
* upgrade: Blender saves real preferences, that version folder is renamed to
  the previous version, and on the next launch Blender offers to load the
  previous settings and copies them forward, as it will after an app update.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path


# Read from the app under test in main(); builds and rebrands use different identifiers.
BUNDLE_ID = ""
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
CASES = ("migrate", "fresh", "upgrade")

STARTUP_PROBE = '''\
import json
import os

_marker = os.path.join(os.path.dirname(__file__), "..", "..", "..", "probe-ran.json")
with open(os.path.normpath(_marker), "w") as handle:
    json.dump({"file": __file__}, handle)


def register():
    pass


def unregister():
    pass
'''

REPORT_EXPR = '''\
import bpy, json, os
_documents = os.path.expanduser("~/Documents")
_copy_prev = bpy.types.PREFERENCES_OT_copy_prev
_report = {
    "user": bpy.utils.resource_path("USER"),
    "config": bpy.utils.user_resource("CONFIG"),
    "documents": _documents,
    "previous_version": list(_copy_prev.previous_version() or []),
    "can_load_previous": bool(_copy_prev.poll(bpy.context)),
    "version": list(bpy.app.version[:2]),
}
if _report["can_load_previous"] and os.environ.get("SETTINGS_LOAD_PREVIOUS"):
    bpy.ops.preferences.copy_prev()
    _report["loaded_previous"] = os.path.isfile(
        os.path.join(bpy.utils.resource_path("USER"), "config", "userpref.blend"))
with open(os.path.join(_documents, "..", "tmp", "settings-report.json"), "w") as handle:
    json.dump(_report, handle)
'''

SAVE_PREFERENCES_EXPR = '''\
import bpy, os
bpy.context.preferences.view.ui_scale = 1.23
bpy.ops.wm.save_userpref()
open(os.path.join(os.path.expanduser("~/tmp"), "saved-preferences"), "w").close()
'''


class SettingsFailure(RuntimeError):
    pass


def run(*args: str, check: bool = True,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, capture_output=True, text=True, env=env)


def wait_for_marker(path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.5)
    raise SettingsFailure(f"timed out waiting for {path.name}")


def wait_for(path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size > 0:
            return
        time.sleep(0.5)
    raise SettingsFailure(f"timed out waiting for {path.name}")


def seed(case: str, container: Path, version: str, previous: str) -> None:
    legacy = container / "Library" / "Application Support" / "Blender"
    documents = container / "Documents"
    if case == "migrate":
        startup = legacy / version / "scripts" / "startup"
        startup.mkdir(parents=True)
        (startup / "settings_probe.py").write_text(STARTUP_PROBE)
        config = legacy / version / "config"
        config.mkdir(parents=True)
        (config / "bookmarks.txt").write_text("[Bookmarks]\n/settings-migration-sentinel\n")
    elif case == "upgrade":
        if not (documents / "Settings" / version / "config" / "userpref.blend").is_file():
            raise SettingsFailure("the setup launch did not save preferences")
        (documents / "Settings" / version).rename(documents / "Settings" / previous)


def validate(case: str, container: Path, report: dict, version: str, previous: str) -> list[str]:
    """Return the failed expectations for one case. An empty list means it passed."""
    documents = container / "Documents"
    settings = documents / "Settings"
    legacy = container / "Library" / "Application Support" / "Blender"
    failures = []

    def expect(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    user = Path(report["user"]).resolve()
    expect(user == (settings / version).resolve(), f"USER resources at {user}")
    expect((settings / "README.txt").is_file(), "README.txt is missing")
    expect(not legacy.exists(), "the hidden Application Support/Blender folder still exists")

    if case == "migrate":
        probe = settings / "probe-ran.json"
        expect(probe.is_file(), "the migrated user startup script did not run")
        if probe.is_file():
            ran_from = Path(json.loads(probe.read_text())["file"]).resolve()
            expect(settings.resolve() in ran_from.parents,
                   f"startup script ran from {ran_from}")
        bookmarks = settings / version / "config" / "bookmarks.txt"
        expect(bookmarks.is_file() and "settings-migration-sentinel" in bookmarks.read_text(),
               "migrated bookmarks are missing")
    elif case == "fresh":
        expect(not (settings / version / "config" / "userpref.blend").exists(),
               "preferences were written before Quick Setup")
    elif case == "upgrade":
        expect(report["previous_version"] == [int(p) for p in previous.split(".")],
               f"previous version {report['previous_version']}")
        expect(report["can_load_previous"], "Load Previous Settings is unavailable")
        expect(report.get("loaded_previous", False), "previous preferences were not copied")
        expect((settings / previous / "config" / "userpref.blend").is_file(),
               "the previous version folder was not kept")
    return failures


def exercise(app: Path, udid: str, case: str, output: Path, version: str, previous: str) -> None:
    run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
    run("xcrun", "simctl", "uninstall", udid, BUNDLE_ID, check=False)
    run("xcrun", "simctl", "install", udid, str(app))
    container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data")
                     .stdout.strip())
    case_output = output / case
    case_output.mkdir(parents=True, exist_ok=True)
    if case == "upgrade":
        saved = container / "tmp" / "saved-preferences"
        run("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE_ID,
            "--python-exit-code", "7", "--python-expr", SAVE_PREFERENCES_EXPR)
        wait_for_marker(saved, 180)
        run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
    seed(case, container, version, previous)
    report_path = container / "tmp" / "settings-report.json"
    report_path.unlink(missing_ok=True)

    # simctl passes SIMCTL_CHILD_* variables to the app without the prefix.
    env = dict(os.environ, SIMCTL_CHILD_SETTINGS_LOAD_PREVIOUS="1")
    launch = run("xcrun", "simctl", "launch", "--terminate-running-process",
                 f"--stdout={case_output / 'app-stdout.txt'}",
                 f"--stderr={case_output / 'app-stderr.txt'}",
                 udid, BUNDLE_ID, "--python-exit-code", "7", "--python-expr", REPORT_EXPR,
                 env=env)
    (case_output / "launch.txt").write_text(launch.stdout + launch.stderr)
    try:
        wait_for(report_path, 180)
        report = json.loads(report_path.read_text())
        (case_output / "report.json").write_text(json.dumps(report, indent=2))
        listing = sorted(str(p.relative_to(container)) for p in (container / "Documents").rglob("*"))
        (case_output / "documents.txt").write_text("\n".join(listing) + "\n")
        failures = validate(case, container, report, version, previous)
    except SettingsFailure:
        run("xcrun", "simctl", "io", udid, "screenshot", "/tmp/settings-failure.png", check=False)
        if Path("/tmp/settings-failure.png").exists():
            shutil.move("/tmp/settings-failure.png", case_output / "failure.png")
        raise
    finally:
        run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
    if failures:
        raise SettingsFailure(f"{case}: " + "; ".join(failures))
    print(f"[{case}] PASS", flush=True)


def bundle_identifier(app: Path) -> str:
    with (app / "Info.plist").open("rb") as handle:
        return plistlib.load(handle)["CFBundleIdentifier"]


def app_versions(app: Path) -> tuple[str, str]:
    """The app's Blender version folder, such as 5.3, and the one before it, such as 5.2.

    The version before a major release such as 6.0 is unknown here, so it is empty.
    """
    with (app / "Info.plist").open("rb") as handle:
        major, minor = plistlib.load(handle)["CFBundleShortVersionString"].split(".")[:2]
    return f"{major}.{minor}", f"{major}.{int(minor) - 1}" if int(minor) else ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--version", help="Blender version folder, defaults to the app's version")
    parser.add_argument("--previous", help="Version to upgrade from, defaults to the minor before")
    args = parser.parse_args()
    global BUNDLE_ID
    BUNDLE_ID = bundle_identifier(args.app)
    version, previous = app_versions(args.app)
    args.version = args.version or version
    args.previous = args.previous or previous
    if not args.previous:
        parser.error("--previous is required for a major version")

    args.output.mkdir(parents=True, exist_ok=True)
    runtime = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json").stdout)
    ios = [r for r in runtime["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
    udid = run("xcrun", "simctl", "create", "settings-location", DEVICE_TYPE,
               ios[-1]["identifier"]).stdout.strip()
    try:
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        failed = False
        for case in args.case or CASES:
            try:
                exercise(args.app, udid, case, args.output, args.version, args.previous)
            except SettingsFailure as error:
                print(f"[{case}] FAIL: {error}", flush=True)
                failed = True
        return 1 if failed else 0
    finally:
        run("xcrun", "simctl", "shutdown", udid, check=False)
        run("xcrun", "simctl", "delete", udid, check=False)


if __name__ == "__main__":
    sys.exit(main())
