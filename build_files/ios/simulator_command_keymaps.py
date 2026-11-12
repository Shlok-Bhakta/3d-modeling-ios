#!/usr/bin/env python3
"""Check that the running app registers Mac Command shortcuts (issue #66).

Run against a dedicated booted simulator. Blender starts from factory settings and
reports which Command and Ctrl shortcuts its default keymap holds. Python reports
``ios`` there, which is the platform the keymap presets have to recognize.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


# (keymap, operator, key): each must work with Ctrl and with Command.
SHORTCUTS = (
    ("Window", "wm.save_mainfile", "S"),
    ("Screen", "ed.undo", "Z"),
    ("Mesh", "mesh.select_linked", "L"),
)


NAMES = {"ctrl": "Ctrl", "oskey": "Cmd"}


class KeymapFailure(RuntimeError):
    pass


def validate(state: dict) -> list[str]:
    if state.get("error"):
        return [state["error"]]
    failures = []
    if state.get("platform") != "ios":
        failures.append(f"Python reports {state.get('platform')!r}, expected 'ios'")
    for keymap, operator, key in SHORTCUTS:
        found = state.get("shortcuts", {}).get(operator, [])
        for modifier in ("ctrl", "oskey"):
            if modifier not in found:
                failures.append(f"{keymap}: {operator} has no {NAMES[modifier]}+{key}")
    return failures


def probe_source(directory: Path) -> str:
    return f'''import bpy, json, sys, traceback
from pathlib import Path
state = {{"platform": sys.platform, "shortcuts": {{}}}}
try:
    keyconfig = bpy.context.window_manager.keyconfigs.default
    for keymap, operator, key in {SHORTCUTS!r}:
        found = state["shortcuts"].setdefault(operator, [])
        for item in keyconfig.keymaps[keymap].keymap_items:
            if item.idname == operator and item.type == key and not item.shift and not item.alt:
                if item.ctrl and not item.oskey:
                    found.append("ctrl")
                elif item.oskey and not item.ctrl:
                    found.append("oskey")
except Exception:
    state["error"] = traceback.format_exc()
Path({str(directory / "state.json")!r}).write_text(json.dumps(state))
'''


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def exercise(app: Path, device: str, timeout: float) -> dict:
    bundle = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    run("xcrun", "simctl", "install", device, str(app))
    container = Path(run("xcrun", "simctl", "get_app_container", device, bundle, "data"))
    with tempfile.TemporaryDirectory(prefix="command-keymaps-", dir=container / "tmp") as name:
        directory = Path(name)
        run("xcrun", "simctl", "launch", "--terminate-running-process",
            f"--stderr={directory / 'stderr.txt'}", device, bundle, "--factory-startup",
            "--python-expr", f"exec({probe_source(directory)!r})")
        try:
            path = directory / "state.json"
            deadline = time.monotonic() + timeout
            while not path.exists() and time.monotonic() < deadline:
                time.sleep(.2)
            if not path.exists():
                raise KeymapFailure("Blender did not report its keymap")
            state = json.loads(path.read_text())
            failures = validate(state)
            if failures:
                raise KeymapFailure("; ".join(failures) + f"\nstate={state}")
            return state
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", device, bundle], capture_output=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    print(json.dumps(exercise(args.app.resolve(), args.device, args.timeout), indent=2))


if __name__ == "__main__":
    main()
