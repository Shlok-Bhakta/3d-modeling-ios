#!/usr/bin/env python3
"""Reject an EEVEE Metal pipeline and verify rendering returns to a live main loop.

Run against a dedicated booted simulator. The temporary library changes Metal's
pipeline-creation result, while Blender's dispatch and render code run unchanged.
This reproduces failure handling, not the capabilities of an older physical GPU.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


class ComputeFailure(RuntimeError):
    pass


def validate_state(state: dict) -> None:
    if state.get("error"):
        raise ComputeFailure(state["error"])
    if state.get("completed_renders") != 3:
        raise ComputeFailure("the two rejected-pipeline renders and normal render must finish")
    if state.get("failed_pipelines", 0) < 2:
        raise ComputeFailure("Metal did not reject the pipeline on repeated renders")
    if state.get("recovered_pipelines", 0) < 1:
        raise ComputeFailure("Metal did not create a working pipeline after restoring support")
    if state.get("post_render_ticks", 0) < 3:
        raise ComputeFailure("the main loop did not resume after rendering")


def probe_source(directory: Path, fixture: Path) -> str:
    return f'''import bpy, ctypes, json, traceback
from pathlib import Path
root = Path({str(directory)!r})
fixture = ctypes.CDLL({str(fixture)!r})
state = {{'completed_renders': 0, 'post_render_ticks': 0,
          'failed_pipelines': 0, 'recovered_pipelines': 0}}
bpy.context.preferences.view.show_splash = False
scene = bpy.context.scene
scene.render.engine = 'BLENDER_EEVEE'
scene.render.resolution_x = 64
scene.render.resolution_y = 64
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.eevee.taa_render_samples = 1
scene.eevee.use_raytracing = True
material = bpy.data.materials.new('Compute failure regression')
material.use_nodes = True
bpy.data.objects['Cube'].data.materials.clear()
bpy.data.objects['Cube'].data.materials.append(material)
fixture.blender_test_fail_ray_pipeline()
def save_state():
    temporary = root / 'state.new'
    temporary.write_text(json.dumps(state))
    temporary.replace(root / 'state.json')
def tick():
    try:
        if state['completed_renders'] < 3:
            index = state['completed_renders']
            if index == 2:
                fixture.blender_test_restore_ray_pipeline()
            state['stage'] = 'render-' + str(index)
            save_state()
            scene.render.filepath = str(root / ('render-' + str(index) + '.png'))
            bpy.ops.render.render(write_still=True)
            state['completed_renders'] += 1
            state['failed_pipelines'] = fixture.blender_test_pipeline_failures()
            state['recovered_pipelines'] = fixture.blender_test_recovered_pipelines()
        else:
            state['post_render_ticks'] += 1
        save_state()
        return .2 if state['post_render_ticks'] < 3 else None
    except Exception:
        state['error'] = traceback.format_exc()
        save_state()
        return None
bpy.app.timers.register(tick, first_interval=2)
'''


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def exercise(app: Path, device: str, timeout: float) -> dict:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    bundle = info["CFBundleIdentifier"]
    run("xcrun", "simctl", "install", device, str(app))
    container = Path(run("xcrun", "simctl", "get_app_container", device, bundle, "data"))
    with tempfile.TemporaryDirectory(prefix="compute-failure-", dir=container / "tmp") as name:
        directory = Path(name)
        fixture = directory / "pipeline-failure.dylib"
        run("xcrun", "--sdk", "iphonesimulator", "clang++", "-std=c++17", "-dynamiclib",
            "-target", "arm64-apple-ios18.0-simulator", "-framework", "Foundation",
            "-framework", "Metal", str(Path(__file__).with_name("metal_compute_failure_fixture.mm")),
            "-o", str(fixture))
        run("codesign", "-s", "-", str(fixture))
        source = probe_source(directory, fixture)
        run("xcrun", "simctl", "launch", "--terminate-running-process",
            f"--stdout={directory / 'stdout.txt'}", f"--stderr={directory / 'stderr.txt'}",
            device, bundle, "--factory-startup", "--python-exit-code", "7",
            "--python-expr", f"exec({source!r})")
        state = {}
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                path = directory / "state.json"
                if path.exists():
                    state = json.loads(path.read_text())
                    if state.get("error") or state.get("post_render_ticks", 0) >= 3:
                        break
                time.sleep(.2)
            validate_state(state)
            from simulator_render_smoke import png_pixels
            width, height, pixels = png_pixels(directory / "render-2.png")
            if (width, height) != (64, 64) or len(set(pixels)) < 8:
                raise ComputeFailure("normal rendering did not recover after pipeline rejection")
            return state
        except ComputeFailure as error:
            log = directory / "stderr.txt"
            detail = log.read_text()[-3000:] if log.exists() else ""
            raise ComputeFailure(f"{error}; last state={state}\n{detail}") from error
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", device, bundle],
                           capture_output=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    print(json.dumps(exercise(args.app.resolve(), args.device, args.timeout), indent=2))


if __name__ == "__main__":
    main()
