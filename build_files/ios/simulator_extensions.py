#!/usr/bin/env python3

"""Install an extension from extensions.blender.org on a real simulator.

iOS apps can't start processes, and Blender's extension system runs its
repository commands (sync, install, uninstall) as a child Python process on
desktop. This harness drives the same modal operators the Preferences buttons
use, so it fails the way people saw in issue #64 when that path is broken:

1. Refresh the blender.org repository (Check for Updates).
2. Install the smallest pure-Python add-on from the downloaded list.
3. Uninstall it again.

Each step must finish, leave the repository unlocked and log no Python errors.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import time
from pathlib import Path


# Read from the app under test in main(); builds and rebrands use different identifiers.
BUNDLE_ID = ""
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
REPORT_NAME = "extensions-report.json"
STEPS = ("sync", "install", "uninstall")

EXTENSIONS_EXPR = '''\
import bpy, json, os, time, traceback

_report = {"steps": {}, "errors": []}
_path = os.path.join(os.path.expanduser("~/tmp"), "extensions-report.json")
_state = {"step": None, "began": 0.0, "pkg_id": None}


def _repo():
    for index, repo in enumerate(bpy.context.preferences.extensions.repos):
        if repo.use_remote_url and "extensions.blender.org" in repo.remote_url:
            return index, repo
    raise RuntimeError("the extensions.blender.org repository is missing")


def _locked(repo):
    from bl_pkg import bl_extension_utils, cookie_from_session
    return bl_extension_utils.repo_lock_directory_query(repo.directory, cookie_from_session()) is not None


def _pick_package(repo):
    with open(os.path.join(repo.directory, ".blender_ext", "index.json"), encoding="utf-8") as handle:
        data = json.load(handle)["data"]
    candidates = [
        item for item in data
        if item.get("type") == "add-on" and not item.get("platforms") and not item.get("wheels")
        and tuple(int(p) for p in item.get("blender_version_min", "0").split(".")[:2]) <= bpy.app.version[:2]
    ]
    return min(candidates, key=lambda item: item.get("archive_size", 1 << 62))["id"]


def _installed(repo, pkg_id):
    return os.path.isfile(os.path.join(repo.directory, pkg_id, "blender_manifest.toml"))


def _start(step):
    index, repo = _repo()
    window = bpy.context.window_manager.windows[0]
    with bpy.context.temp_override(window=window, area=None, region=None):
        if step == "sync":
            result = bpy.ops.extensions.repo_sync_all("INVOKE_DEFAULT")
        elif step == "install":
            _state["pkg_id"] = _pick_package(repo)
            result = bpy.ops.extensions.package_install(
                "INVOKE_DEFAULT", repo_directory=repo.directory, repo_index=index,
                pkg_id=_state["pkg_id"], enable_on_install=True)
        else:
            result = bpy.ops.extensions.package_uninstall(
                "EXEC_DEFAULT", repo_directory=repo.directory, repo_index=index,
                pkg_id=_state["pkg_id"])
    _report["steps"][step] = {"result": sorted(result), "pkg_id": _state["pkg_id"]}
    _state["step"] = step
    _state["began"] = time.monotonic()


def _done(step, repo):
    if _locked(repo):
        return False
    if step == "sync":
        return os.path.isfile(os.path.join(repo.directory, ".blender_ext", "index.json"))
    if step == "install":
        return _installed(repo, _state["pkg_id"])
    return not _installed(repo, _state["pkg_id"])


def _write():
    with open(_path, "w", encoding="utf-8") as handle:
        json.dump(_report, handle, indent=2)


def _tick():
    try:
        _index, repo = _repo()
        step = _state["step"]
        if step is None:
            _start("sync")
            return 0.5
        entry = _report["steps"][step]
        if _done(step, repo):
            entry["finished"] = True
            entry["seconds"] = round(time.monotonic() - _state["began"], 1)
            if step == "install":
                entry["enabled"] = ("bl_ext.blender_org." + _state["pkg_id"]) in bpy.context.preferences.addons
            following = {"sync": "install", "install": "uninstall"}.get(step)
            if following is None:
                _report["locked_at_end"] = _locked(repo)
                _write()
                return None
            _start(following)
            return 0.5
        if time.monotonic() - _state["began"] > 120.0:
            entry["finished"] = False
            entry["locked"] = _locked(repo)
            _write()
            return None
        return 0.5
    except Exception:
        _report["errors"].append(traceback.format_exc())
        _write()
        return None


bpy.context.preferences.view.show_splash = False
bpy.app.timers.register(_tick, first_interval=3.0)
'''


class ExtensionsFailure(RuntimeError):
    pass


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, capture_output=True, text=True)


def validate(report: dict, logs: str) -> list[str]:
    """Return the failed expectations. An empty list means the run passed."""
    failures = [f"harness error: {error.strip().splitlines()[-1]}" for error in report.get("errors", [])]
    for step in STEPS:
        entry = report.get("steps", {}).get(step)
        if entry is None:
            failures.append(f"{step} did not start")
            continue
        if not entry.get("finished"):
            failures.append(f"{step} did not finish (locked: {entry.get('locked')})")
    install = report.get("steps", {}).get("install", {})
    if install.get("finished") and not install.get("enabled"):
        failures.append(f"{install.get('pkg_id')} installed but was not enabled")
    if report.get("locked_at_end"):
        failures.append("the repository is still locked")
    for marker in ("does not support processes", "Traceback (most recent call last)"):
        if marker in logs:
            failures.append(f"app log contains {marker!r}")
    return failures


def exercise(app: Path, udid: str, output: Path) -> None:
    run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
    run("xcrun", "simctl", "uninstall", udid, BUNDLE_ID, check=False)
    run("xcrun", "simctl", "install", udid, str(app))
    container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data")
                     .stdout.strip())
    report_path = container / "tmp" / REPORT_NAME
    report_path.unlink(missing_ok=True)
    stderr_path = output / "app-stderr.txt"
    launch = run("xcrun", "simctl", "launch", "--terminate-running-process",
                 f"--stdout={output / 'app-stdout.txt'}", f"--stderr={stderr_path}",
                 udid, BUNDLE_ID, "--online-mode", "--python-exit-code", "7",
                 "--python-expr", EXTENSIONS_EXPR, check=False)
    (output / "launch.txt").write_text(launch.stdout + launch.stderr)
    if launch.returncode:
        raise ExtensionsFailure(f"launch failed: {launch.stderr.strip()}")
    try:
        deadline = time.monotonic() + 420
        while not (report_path.exists() and report_path.stat().st_size):
            if time.monotonic() > deadline:
                raise ExtensionsFailure(f"timed out waiting for {REPORT_NAME}")
            time.sleep(1.0)
        time.sleep(1.0)
        report = json.loads(report_path.read_text())
        (output / "report.json").write_text(json.dumps(report, indent=2))
    except ExtensionsFailure:
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / "failure.png"), check=False)
        raise
    finally:
        run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
    # Blender prints Python errors to stdout.
    logs = "".join(path.read_text(errors="replace") for path in
                   (output / "app-stdout.txt", stderr_path) if path.exists())
    failures = validate(report, logs)
    if failures:
        raise ExtensionsFailure("; ".join(failures))


def bundle_identifier(app: Path) -> str:
    with (app / "Info.plist").open("rb") as handle:
        return plistlib.load(handle)["CFBundleIdentifier"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    global BUNDLE_ID
    BUNDLE_ID = bundle_identifier(args.app)

    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    runtime = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json").stdout)
    ios = [r for r in runtime["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
    udid = run("xcrun", "simctl", "create", "extensions", DEVICE_TYPE,
               ios[-1]["identifier"]).stdout.strip()
    try:
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        try:
            exercise(args.app, udid, args.output)
        except ExtensionsFailure as error:
            print(f"[extensions] FAIL: {error}", flush=True)
            return 1
        print("[extensions] PASS", flush=True)
        return 0
    finally:
        run("xcrun", "simctl", "shutdown", udid, check=False)
        run("xcrun", "simctl", "delete", udid, check=False)


if __name__ == "__main__":
    raise SystemExit(main())
