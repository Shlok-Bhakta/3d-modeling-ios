#!/usr/bin/env python3

"""Round-trip interchange formats through a real simulator build.

Some file formats depend on native libraries the iOS port cross-compiles and
bundles. Each check drives the same operators a person would use and verifies
the file that comes back, so a missing or unreachable library fails here the
way it fails in the app:

gltf-bridges: export a mesh to glTF with Draco and with meshopt compression,
              then import each file again and compare the geometry.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import time
from pathlib import Path


DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
REPORT_NAME = "interchange-report.json"
MESH_CODECS = {
    "draco": ("export_draco_mesh_compression_enable", "KHR_draco_mesh_compression"),
    "meshopt": ("export_meshopt_compression_enable", "EXT_meshopt_compression"),
}

COMMON_EXPR = '''\
import bpy, json, os, traceback

_report = {"check": CHECK, "errors": []}
_work = os.path.join(os.path.expanduser("~/tmp"), CHECK + "-roundtrip")
os.makedirs(_work, exist_ok=True)


def _window_override():
    window = bpy.context.window_manager.windows[0]
    return bpy.context.temp_override(window=window, area=None, region=None)


def _write():
    path = os.path.join(os.path.expanduser("~/tmp"), "interchange-report.json")
    with open(path + ".part", "w", encoding="utf-8") as handle:
        json.dump(_report, handle)
    os.replace(path + ".part", path)


def _gltf_document(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)
'''

GLTF_BRIDGES_EXPR = '''\
GRID = 8


def _grid_object():
    vertices = [(x, y, 0.0) for y in range(GRID + 1) for x in range(GRID + 1)]
    faces = [(y * (GRID + 1) + x, y * (GRID + 1) + x + 1, (y + 1) * (GRID + 1) + x + 1,
              (y + 1) * (GRID + 1) + x) for y in range(GRID) for x in range(GRID)]
    mesh = bpy.data.meshes.new("bridge_grid")
    mesh.from_pydata(vertices, [], faces)
    grid = bpy.data.objects.new("bridge_grid", mesh)
    bpy.context.scene.collection.objects.link(grid)
    return grid


def _triangles(objects):
    count = 0
    for obj in objects:
        if obj.type == "MESH":
            obj.data.calc_loop_triangles()
            count += len(obj.data.loop_triangles)
    return count


def _run():
    from io_scene_gltf2.io.com.library import dll_path
    frameworks = os.path.join(os.path.dirname(bpy.app.binary_path), "Frameworks")
    _report["lookup"] = {}
    for name in sorted(os.listdir(frameworks)):
        if name.startswith("libbf_intern_") and name.endswith("_bridge.dylib"):
            lib_name = name[len("lib"):-len(".dylib")]
            path = dll_path(lib_name, lib_name)
            _report["lookup"][lib_name] = {"path": str(path), "found": bool(path and path.is_file())}

    grid = _grid_object()
    _report["expected_triangles"] = GRID * GRID * 2
    _report["codecs"] = {}
    for codec, (option, extension) in MESH_CODECS.items():
        entry = {}
        _report["codecs"][codec] = entry
        gltf_path = os.path.join(_work, codec + ".gltf")
        for obj in bpy.context.scene.objects:
            obj.select_set(obj == grid)
        with _window_override():
            entry["export_result"] = sorted(bpy.ops.export_scene.gltf(
                filepath=gltf_path, export_format="GLTF_SEPARATE", use_selection=True,
                **{option: True}))
        entry["extension_used"] = extension in _gltf_document(gltf_path).get("extensionsUsed", [])
        before = set(bpy.data.objects.keys())
        with _window_override():
            entry["import_result"] = sorted(bpy.ops.import_scene.gltf(filepath=gltf_path))
        imported = [bpy.data.objects[name] for name in bpy.data.objects.keys() if name not in before]
        entry["imported_triangles"] = _triangles(imported)
'''

RUNNER_EXPR = '''\


def _tick():
    try:
        _run()
    except Exception:
        _report["errors"].append(traceback.format_exc())
    _write()
    return None


bpy.app.timers.register(_tick, first_interval=3.0)
'''

CHECKS = {
    "gltf-bridges": f"MESH_CODECS = {MESH_CODECS!r}\n" + GLTF_BRIDGES_EXPR,
}


class InterchangeFailure(RuntimeError):
    pass


def python_expr(check: str) -> str:
    return f"CHECK = {check!r}\n" + COMMON_EXPR + CHECKS[check] + RUNNER_EXPR


def validate_gltf_bridges(report: dict) -> list[str]:
    failures = []
    lookup = report.get("lookup", {})
    if not lookup:
        failures.append("no glTF bridge is packaged in Frameworks")
    for name, entry in sorted(lookup.items()):
        if not entry.get("found"):
            failures.append(f"glTF add-on looks for {name} at {entry.get('path')}")
    codecs = report.get("codecs", {})
    for codec, (_option, extension) in MESH_CODECS.items():
        entry = codecs.get(codec)
        if entry is None:
            failures.append(f"{codec} export did not run")
            continue
        if entry.get("export_result") != ["FINISHED"]:
            failures.append(f"{codec} export returned {entry.get('export_result')}")
        if not entry.get("extension_used"):
            failures.append(f"{codec} export did not use {extension}")
        if entry.get("imported_triangles") != report.get("expected_triangles"):
            failures.append(f"{codec} import has {entry.get('imported_triangles')} triangles, "
                            f"expected {report.get('expected_triangles')}")
    return failures


VALIDATORS = {
    "gltf-bridges": validate_gltf_bridges,
}


def validate(report: dict, logs: str) -> list[str]:
    """Return the failed expectations. An empty list means the run passed."""
    failures = [f"harness error: {error.strip().splitlines()[-1]}" for error in report.get("errors", [])]
    failures += VALIDATORS[report["check"]](report)
    if "Traceback (most recent call last)" in logs:
        failures.append("app log contains a Python traceback")
    return failures


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, capture_output=True, text=True)


def bundle_identifier(app: Path) -> str:
    with (app / "Info.plist").open("rb") as handle:
        return plistlib.load(handle)["CFBundleIdentifier"]


def exercise(app: Path, udid: str, check: str, output: Path) -> None:
    bundle_id = bundle_identifier(app)
    run("xcrun", "simctl", "terminate", udid, bundle_id, check=False)
    run("xcrun", "simctl", "uninstall", udid, bundle_id, check=False)
    run("xcrun", "simctl", "install", udid, str(app))
    container = Path(run("xcrun", "simctl", "get_app_container", udid, bundle_id, "data")
                     .stdout.strip())
    report_path = container / "tmp" / REPORT_NAME
    report_path.unlink(missing_ok=True)
    stdout_path = output / "app-stdout.txt"
    stderr_path = output / "app-stderr.txt"
    launch = run("xcrun", "simctl", "launch", "--terminate-running-process",
                 f"--stdout={stdout_path}", f"--stderr={stderr_path}",
                 udid, bundle_id, "--python-exit-code", "7",
                 "--python-expr", python_expr(check), check=False)
    (output / "launch.txt").write_text(launch.stdout + launch.stderr)
    if launch.returncode:
        raise InterchangeFailure(f"launch failed: {launch.stderr.strip()}")
    try:
        deadline = time.monotonic() + 300
        while not report_path.exists():
            if time.monotonic() > deadline:
                raise InterchangeFailure(f"timed out waiting for {REPORT_NAME}")
            time.sleep(1.0)
        report = json.loads(report_path.read_text())
        (output / "report.json").write_text(json.dumps(report, indent=2))
    except InterchangeFailure:
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / "failure.png"), check=False)
        raise
    finally:
        run("xcrun", "simctl", "terminate", udid, bundle_id, check=False)
    # Blender prints Python errors to stdout.
    logs = "".join(path.read_text(errors="replace") for path in (stdout_path, stderr_path)
                   if path.exists())
    failures = validate(report, logs)
    if failures:
        raise InterchangeFailure("; ".join(failures))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--check", required=True, choices=sorted(CHECKS))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    output = args.output.resolve() / args.check
    output.mkdir(parents=True, exist_ok=True)
    runtime = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json").stdout)
    ios = [r for r in runtime["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
    udid = run("xcrun", "simctl", "create", f"interchange-{args.check}", DEVICE_TYPE,
               ios[-1]["identifier"]).stdout.strip()
    try:
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        try:
            exercise(args.app.resolve(), udid, args.check, output)
        except InterchangeFailure as error:
            print(f"[interchange:{args.check}] FAIL: {error}", flush=True)
            return 1
        print(f"[interchange:{args.check}] PASS", flush=True)
        return 0
    finally:
        run("xcrun", "simctl", "shutdown", udid, check=False)
        run("xcrun", "simctl", "delete", udid, check=False)


if __name__ == "__main__":
    raise SystemExit(main())
