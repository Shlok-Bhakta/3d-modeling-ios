#!/usr/bin/env python3

"""Drive the on-screen Shift, Ctrl, Alt and Cmd keys on a real simulator (issue #57).

The app starts with a window-level Blender modal operator that records every
mouse press and the modifiers Blender sees on it. Maestro then uses the belt
through its accessibility identifiers and taps the screen, which clicks at the
virtual cursor. Maestro opens the belt, and the repository's HID helper sends
the touches with real timing. The recorded presses must show:

1. a tapped (latched) Shift on the next click only,
2. a double-tapped (locked) Ctrl on every click until it's tapped off,
3. Alt combined with locked Ctrl,
4. a tapped Cmd, which Blender sees as its OS key, on the next click only,
5. no modifiers once everything is off,

and the belt must remember the corner it was dragged to.
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
CORNER_KEY = "GHOST_IOSModifierBeltCorner"
TOP_LEFT = 0

EVENT_LOGGER = '''\
import bpy, json, os, time
# Python arguments run before the splash opens; keep it from taking the clicks.
bpy.context.preferences.view.show_splash = False
_log_path = os.path.join(os.path.expanduser("~/tmp"), "belt-events.json")
_events = []
_trace_path = os.path.join(os.path.expanduser("~/tmp"), "belt-trace.json")
_trace = []


class IOS_OT_belt_event_log(bpy.types.Operator):
    bl_idname = "wm.ios_belt_event_log"
    bl_label = "Log modifier events"

    def modal(self, context, event):
        if event.type == 'LEFTMOUSE' and event.value in {'PRESS', 'DOUBLE_CLICK'}:
            _events.append({"shift": event.shift, "ctrl": event.ctrl, "alt": event.alt,
                            "oskey": event.oskey})
            with open(_log_path, "w") as handle:
                json.dump(_events, handle)
        if event.type in {'LEFTMOUSE', 'LEFT_SHIFT', 'LEFT_CTRL', 'LEFT_ALT', 'OSKEY'}:
            _trace.append([time.monotonic(), event.type, event.value, event.shift, event.ctrl,
                           event.alt, event.oskey])
            with open(_trace_path, "w") as handle:
                json.dump(_trace, handle)
        return {'PASS_THROUGH'}

    def invoke(self, context, event):
        context.window_manager.modal_handler_add(self)
        with open(_log_path, "w") as handle:
            json.dump(_events, handle)
        return {'RUNNING_MODAL'}


bpy.utils.register_class(IOS_OT_belt_event_log)


_heartbeat_path = os.path.join(os.path.expanduser("~/tmp"), "belt-heartbeat")


def _heartbeat():
    with open(_heartbeat_path, "w") as handle:
        handle.write(str(time.monotonic()))
    return 0.1


bpy.app.timers.register(_heartbeat, first_interval=0.1, persistent=True)


def _start():
    window = bpy.context.window_manager.windows[0]
    with bpy.context.temp_override(window=window, screen=window.screen):
        bpy.ops.wm.ios_belt_event_log('INVOKE_DEFAULT')
    return None


bpy.app.timers.register(_start, first_interval=2.0)
'''

# Maestro only opens the belt; the HID helper then drives every touch so taps
# and the double tap have real, human timing.
OPEN_FLOW = '''\
- assertVisible:
    id: blender_modifier_belt_handle
# A second tap would close the belt again, so never retry it.
- tapOn:
    id: blender_modifier_belt_handle
    retryTapIfNoChange: false
- extendedWaitUntil:
    visible:
      id: blender_modifier_shift
    timeout: 20000
- assertVisible:
    id: blender_modifier_control
- assertVisible:
    id: blender_modifier_alt
- assertVisible:
    id: blender_modifier_command
- takeScreenshot: modifier-belt-expanded
'''

BELT_IDS = (
    "blender_modifier_belt_handle",
    "blender_modifier_shift",
    "blender_modifier_control",
    "blender_modifier_alt",
    "blender_modifier_command",
)
# A finger tap clicks at the virtual cursor, which starts in the middle of the window.
VIEWPORT = (0.5, 0.5)
# Long enough between clicks that UIKit can't merge them into a double or triple tap.
CLICK_GAP = 1.2

EXPECTED = [
    {"shift": False, "ctrl": False, "alt": False, "oskey": False},
    {"shift": True, "ctrl": False, "alt": False, "oskey": False},
    {"shift": False, "ctrl": False, "alt": False, "oskey": False},
    {"shift": False, "ctrl": True, "alt": False, "oskey": False},
    {"shift": False, "ctrl": True, "alt": False, "oskey": False},
    {"shift": False, "ctrl": True, "alt": True, "oskey": False},
    {"shift": False, "ctrl": False, "alt": False, "oskey": False},
    {"shift": False, "ctrl": False, "alt": False, "oskey": True},
    {"shift": False, "ctrl": False, "alt": False, "oskey": False},
]


def run(*args: str, check: bool = True,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, capture_output=True, text=True, env=env)


def validate(events: list[dict], corner: int | None) -> list[str]:
    """Return the failed expectations. An empty list means the belt worked."""
    failures = []
    if events != EXPECTED:
        failures.append(f"click modifiers {events}, expected {EXPECTED}")
    if corner != TOP_LEFT:
        failures.append(f"belt corner {corner}, expected top left ({TOP_LEFT})")
    return failures


def element_centers(hierarchy: dict) -> tuple[dict[str, tuple[float, float]], tuple[float, float]]:
    """Return normalized centers of the belt elements and the screen size in points."""
    centers: dict[str, tuple[float, float]] = {}
    screen = [0.0, 0.0]

    def visit(node: dict) -> None:
        attributes = node.get("attributes", {})
        bounds = attributes.get("bounds", "")
        numbers = [float(n) for n in bounds.replace("][", ",").strip("[]").split(",") if n]
        if len(numbers) == 4:
            screen[0] = max(screen[0], numbers[2])
            screen[1] = max(screen[1], numbers[3])
            identifier = attributes.get("resource-id", "")
            if identifier in BELT_IDS:
                centers[identifier] = ((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2)
        for child in node.get("children", []):
            visit(child)

    visit(hierarchy)
    normalized = {key: (x / screen[0], y / screen[1]) for key, (x, y) in centers.items()}
    return normalized, (screen[0], screen[1])


def tap(point: tuple[float, float], wait: float) -> list[dict]:
    return [
        {"points": [list(point)], "phase": 1, "wait": wait},
        {"points": [list(point)], "phase": 2, "wait": 0.06},
    ]


def touch_segments(centers: dict[str, tuple[float, float]]) -> list[list[dict]]:
    """Touches in steps. The harness waits for Blender to be responsive between steps, because
    UIKit shares Blender's main thread and a stalled frame reorders delayed taps."""
    shift = centers["blender_modifier_shift"]
    control = centers["blender_modifier_control"]
    alt = centers["blender_modifier_alt"]
    command = centers["blender_modifier_command"]
    handle = centers["blender_modifier_belt_handle"]
    # Drag the handle to the top-left quarter and let go.
    target = (0.12, 0.12)
    steps = 24
    drag = [{"points": [list(handle)], "phase": 1, "wait": 0.5}]
    for i in range(1, steps + 1):
        x = handle[0] + (target[0] - handle[0]) * i / steps
        y = handle[1] + (target[1] - handle[1]) * i / steps
        drag.append({"points": [[x, y]], "phase": 6, "wait": 0.025})
    drag.append({"points": [list(target)], "phase": 2, "wait": 0.05})
    drag.append({"idle": True, "wait": 1.5})
    return [
        tap(VIEWPORT, 0.2),                                  # 1: plain
        tap(shift, 0.2) + tap(VIEWPORT, 0.6),                # 2: Shift latched
        tap(VIEWPORT, 0.2),                                  # 3: plain
        tap(control, 0.2) + tap(control, 0.12) + tap(VIEWPORT, 0.6),  # 4: Ctrl locked
        tap(VIEWPORT, 0.2),                                  # 5: Ctrl
        tap(alt, 0.2) + tap(VIEWPORT, 0.6),                  # 6: Ctrl + Alt
        tap(control, 0.2) + tap(VIEWPORT, 0.6),              # 7: plain
        tap(command, 0.2) + tap(VIEWPORT, 0.6),              # 8: Cmd latched
        tap(VIEWPORT, 0.2),                                  # 9: plain
        tap(handle, 0.2) + drag,                             # collapse, then move
    ]


def wait_responsive(heartbeat: Path, steady: float = 3.0, timeout: float = 180.0) -> None:
    """Wait until Blender's timers have run without a stall for `steady` seconds."""
    deadline = time.monotonic() + timeout
    steady_since = None
    last_value = None
    last_change = time.monotonic()
    while time.monotonic() < deadline:
        value = heartbeat.read_text() if heartbeat.exists() else None
        now = time.monotonic()
        if value != last_value:
            last_value = value
            last_change = now
            if steady_since is None:
                steady_since = now
        elif now - last_change > 0.5:
            steady_since = None
        if steady_since is not None and now - steady_since >= steady:
            return
        time.sleep(0.05)
    raise RuntimeError("Blender did not become responsive")


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
    output = args.output
    output.mkdir(parents=True, exist_ok=True)

    runtime = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json").stdout)
    ios = [r for r in runtime["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
    udid = run("xcrun", "simctl", "create", "modifier-belt", DEVICE_TYPE,
               ios[-1]["identifier"]).stdout.strip()
    try:
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        run("xcrun", "simctl", "install", udid, str(args.app))
        container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data")
                         .stdout.strip())
        log_path = container / "tmp" / "belt-events.json"
        # The Simulator always reports a hardware keyboard, which hides the belt.
        env = dict(os.environ, SIMCTL_CHILD_GHOST_IOS_MODIFIER_BELT="always")
        launch = run("xcrun", "simctl", "launch", udid, BUNDLE_ID, "--factory-startup",
                     "--python-exit-code", "7", "--python-expr", EVENT_LOGGER, env=env)
        (output / "launch.txt").write_text(launch.stdout + launch.stderr)
        deadline = time.monotonic() + 180
        while not log_path.exists():
            if time.monotonic() > deadline:
                raise RuntimeError("the event logger did not start")
            time.sleep(0.5)

        heartbeat = container / "tmp" / "belt-heartbeat"
        wait_responsive(heartbeat)
        flow = output / "modifier-belt-open.yaml"
        flow.write_text(f"appId: {BUNDLE_ID}\n---\n{OPEN_FLOW}")
        with (output / "maestro.txt").open("w") as log:
            maestro = subprocess.run(["maestro", "--device", udid, "test", "--test-output-dir",
                                      str(output), str(flow)], stdout=log,
                                     stderr=subprocess.STDOUT)
        if maestro.returncode != 0:
            print(f"FAIL: the belt did not open, see {output / 'maestro.txt'}", flush=True)
            return 1
        hierarchy = json.loads(run("maestro", "--device", udid, "hierarchy").stdout)
        centers, screen = element_centers(hierarchy)
        (output / "belt-elements.json").write_text(
            json.dumps({"screen": screen, "centers": centers}, indent=2))
        missing = [identifier for identifier in BELT_IDS if identifier not in centers]
        if missing:
            print(f"FAIL: belt elements not found: {missing}", flush=True)
            return 1

        helper = output / "simulator_gesture_hid"
        developer = run("xcode-select", "-p").stdout.strip()
        hid_env = dict(os.environ, DEVELOPER_DIR=developer)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-framework", "AppKit", str(Path(__file__).with_name("simulator_gesture_hid.m")),
                        "-o", str(helper)], check=True, env=hid_env)
        segments = touch_segments(centers)
        (output / "touches.json").write_text(json.dumps(segments, indent=1))
        for segment in segments:
            wait_responsive(heartbeat)
            subprocess.run([str(helper), udid], input=json.dumps(segment), text=True,
                           env=hid_env, check=True)
        wait_responsive(heartbeat)
        run("xcrun", "simctl", "io", udid, "screenshot", "/tmp/modifier-belt-moved.png",
            check=False)
        if Path("/tmp/modifier-belt-moved.png").exists():
            shutil.move("/tmp/modifier-belt-moved.png", output / "modifier-belt-moved.png")
        events = json.loads(log_path.read_text())
        (output / "events.json").write_text(json.dumps(events, indent=2))
        trace = container / "tmp" / "belt-trace.json"
        if trace.exists():
            shutil.copy(trace, output / "trace.json")

        run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
        preferences = container / "Library" / "Preferences" / f"{BUNDLE_ID}.plist"
        corner = None
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and corner is None:
            if preferences.exists():
                corner = plistlib.loads(preferences.read_bytes()).get(CORNER_KEY)
            time.sleep(0.5)

        failures = validate(events, corner)
        if failures:
            for failure in failures:
                print(f"FAIL: {failure}", flush=True)
            return 1
        print("PASS: latched, locked, combined and released modifiers; corner remembered",
              flush=True)
        return 0
    finally:
        run("xcrun", "simctl", "shutdown", udid, check=False)
        run("xcrun", "simctl", "delete", udid, check=False)


if __name__ == "__main__":
    sys.exit(main())
