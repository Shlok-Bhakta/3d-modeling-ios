#!/usr/bin/env python3

"""Round-trip interchange formats through a real simulator build.

Some file formats depend on native libraries the iOS port cross-compiles and
bundles. Each check drives the same operators a person would use and verifies
the file that comes back, so a missing or unreachable library fails here the
way it fails in the app:

gltf-bridges: export a mesh to glTF with Draco and with meshopt compression,
              then import each file again and compare the geometry.
ktx: export a textured plane to glTF with KTX2 (BasisU) textures through the
     KTX bridge, then import it again and compare the decoded pixels.
otio: export a VSE timeline with a color and an image strip to OpenTimelineIO,
      then import it again and compare the strips.
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
# BasisU is lossy. Pure quadrant colors come back well inside this per-channel error.
MAX_PIXEL_ERROR = 0.2

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

KTX_EXPR = '''\
SIZE = 16
COLORS = ((1.0, 0.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0), (1.0, 1.0, 1.0, 1.0))
SAMPLES = ((4, 4), (12, 4), (4, 12), (12, 12))
KTX2_MAGIC = bytes((0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A))


def _pixel(pixels, x, y):
    index = (y * SIZE + x) * 4
    return pixels[index:index + 4]


def _source_image():
    image = bpy.data.images.new("ktx_source", SIZE, SIZE, alpha=True)
    pixels = []
    for y in range(SIZE):
        for x in range(SIZE):
            pixels.extend(COLORS[(y >= SIZE // 2) * 2 + (x >= SIZE // 2)])
    image.pixels.foreach_set(pixels)
    image.filepath_raw = os.path.join(_work, "source.png")
    image.file_format = "PNG"
    image.save()
    return image, pixels


def _textured_plane(image):
    material = bpy.data.materials.new("ktx_material")
    tree = material.node_tree
    texture = tree.nodes.new("ShaderNodeTexImage")
    texture.image = image
    shader = next(node for node in tree.nodes if node.type == "BSDF_PRINCIPLED")
    tree.links.new(texture.outputs["Color"], shader.inputs["Base Color"])
    mesh = bpy.data.meshes.new("ktx_plane")
    mesh.from_pydata([(-1, -1, 0), (1, -1, 0), (1, 1, 0), (-1, 1, 0)], [], [(0, 1, 2, 3)])
    uv_layer = mesh.uv_layers.new()
    for loop, uv in zip(uv_layer.data, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop.uv = uv
    mesh.materials.append(material)
    plane = bpy.data.objects.new("ktx_plane", mesh)
    bpy.context.scene.collection.objects.link(plane)


def _run():
    from io_scene_gltf2.io.com.library import dll_path
    bridge = dll_path("bf_intern_ktx_bridge", "KTX")
    _report["bridge"] = {"path": str(bridge), "exists": bool(bridge and bridge.is_file())}

    image, source = _source_image()
    _textured_plane(image)
    gltf_path = os.path.join(_work, "scene.gltf")
    with _window_override():
        result = bpy.ops.export_scene.gltf(
            filepath=gltf_path, export_format="GLTF_SEPARATE",
            export_image_add_compressed_images=True, export_compressed_images_type="KTX2",
            export_compressed_images_fallback=True)
    export = {"result": sorted(result), "ktx2_files": [], "magic_ok": False}
    _report["export"] = export
    document = _gltf_document(gltf_path)
    export["basisu_used"] = "KHR_texture_basisu" in document.get("extensionsUsed", [])
    for entry in document.get("images", []):
        if entry.get("uri", "").endswith(".ktx2"):
            path = os.path.join(_work, entry["uri"])
            export["ktx2_files"].append(entry["uri"])
            with open(path, "rb") as handle:
                export["magic_ok"] = handle.read(len(KTX2_MAGIC)) == KTX2_MAGIC

    before = set(bpy.data.objects.keys())
    with _window_override():
        result = bpy.ops.import_scene.gltf(filepath=gltf_path, import_ktx_texture=True)
    # The importer renames images after the glTF image. A KTX2 texture it decoded is a packed
    # image; one it failed to read is a placeholder pointing at the .ktx2 file.
    imported = []
    for name in bpy.data.objects.keys():
        obj = bpy.data.objects[name]
        if name in before or obj.type != "MESH":
            continue
        for material in obj.data.materials:
            imported += [node.image for node in material.node_tree.nodes
                         if node.type == "TEX_IMAGE" and node.image and node.image.packed_file]
    entry = {"result": sorted(result), "images": [], "max_error": None}
    _report["import"] = entry
    for decoded in imported:
        entry["images"].append({"name": decoded.name, "size": list(decoded.size)})
    if imported and tuple(imported[0].size) == (SIZE, SIZE):
        pixels = list(imported[0].pixels)
        entry["max_error"] = max(
            abs(a - b) for x, y in SAMPLES
            for a, b in zip(_pixel(pixels, x, y), _pixel(source, x, y)))
'''

OTIO_EXPR = '''\
def _operator_exists(name):
    try:
        getattr(bpy.ops.wm, name).get_rna_type()
    except (AttributeError, KeyError):
        return False
    return True


def _media_png():
    image = bpy.data.images.new("otio_frame", 32, 32)
    image.pixels.foreach_set([0.2, 0.4, 0.8, 1.0] * 32 * 32)
    path = os.path.join(_work, "media", "frame.png")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    return path


def _strips(editor):
    summary = {}
    for strip in editor.strips:
        entry = {"type": strip.type, "channel": strip.channel,
                 "start": strip.frame_final_start, "end": strip.frame_final_end}
        if strip.type == "IMAGE":
            entry["media"] = os.path.normpath(os.path.join(
                bpy.path.abspath(strip.directory), strip.elements[0].filename))
        summary[strip.name] = entry
    return summary


def _clip_names(node, names):
    if isinstance(node, dict):
        if str(node.get("OTIO_SCHEMA", "")).startswith("Clip."):
            names.append(node.get("name"))
        for value in node.values():
            _clip_names(value, names)
    elif isinstance(node, list):
        for value in node:
            _clip_names(value, names)
    return names


def _run():
    _report["operators"] = {name: _operator_exists(name) for name in ("otio_export", "otio_import")}
    if not all(_report["operators"].values()):
        return

    scene = bpy.context.scene
    window = bpy.context.window_manager.windows[0]
    window.workspace.sequencer_scene = scene
    editor = scene.sequence_editor_create()
    editor.strips.new_effect(name="Backdrop", type="COLOR", channel=1, frame_start=1, length=48)
    still = editor.strips.new_image(name="Still", filepath=_media_png(), channel=2, frame_start=12)
    still.frame_final_duration = 20
    _report["expected"] = _strips(editor)

    otio_path = os.path.join(_work, "timeline.otio")
    with _window_override():
        export = {"result": sorted(bpy.ops.wm.otio_export(filepath=otio_path))}
    _report["export"] = export
    with open(otio_path, encoding="utf-8") as handle:
        document = json.load(handle)
    export["schema"] = document.get("OTIO_SCHEMA")
    export["clips"] = sorted(_clip_names(document, []))

    before = set(bpy.data.scenes.keys())
    with _window_override():
        result = bpy.ops.wm.otio_import(filepath=otio_path)
    created = [bpy.data.scenes[name] for name in bpy.data.scenes.keys() if name not in before]
    _report["import"] = {
        "result": sorted(result),
        "scenes": [created_scene.name for created_scene in created],
        "strips": _strips(created[0].sequence_editor) if created and created[0].sequence_editor else {},
    }
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
    "ktx": KTX_EXPR,
    "otio": OTIO_EXPR,
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


def validate_ktx(report: dict) -> list[str]:
    failures = []
    bridge = report.get("bridge", {})
    if not bridge.get("exists"):
        failures.append(f"KTX bridge is missing at {bridge.get('path')}")
    export = report.get("export")
    if export is None:
        return failures + ["glTF export did not run"]
    if export.get("result") != ["FINISHED"]:
        failures.append(f"glTF export returned {export.get('result')}")
    if not export.get("basisu_used"):
        failures.append("glTF export did not use KHR_texture_basisu")
    if not export.get("ktx2_files"):
        failures.append("glTF export wrote no KTX2 texture")
    elif not export.get("magic_ok"):
        failures.append("the exported texture is not a KTX2 file")
    imported = report.get("import")
    if imported is None:
        return failures + ["glTF import did not run"]
    if not imported.get("images"):
        failures.append("glTF import decoded no KTX2 texture")
    elif imported.get("max_error") is None:
        failures.append(f"decoded KTX2 texture has the wrong size: {imported['images']}")
    elif imported["max_error"] > MAX_PIXEL_ERROR:
        failures.append(f"decoded KTX2 pixels differ by {imported['max_error']:.3f}")
    return failures


def validate_otio(report: dict) -> list[str]:
    missing = [name for name, found in report.get("operators", {}).items() if not found]
    if missing or not report.get("operators"):
        return [f"OpenTimelineIO operators are not registered: {missing or 'none reported'}"]
    failures = []
    expected = report.get("expected", {})
    export = report.get("export", {})
    if export.get("result") != ["FINISHED"]:
        failures.append(f"OTIO export returned {export.get('result')}")
    if not str(export.get("schema", "")).startswith("Timeline."):
        failures.append(f"the exported file is not an OTIO timeline: {export.get('schema')}")
    if export.get("clips") != sorted(expected):
        failures.append(f"OTIO export wrote clips {export.get('clips')}, expected {sorted(expected)}")
    imported = report.get("import", {})
    if imported.get("result") != ["FINISHED"]:
        failures.append(f"OTIO import returned {imported.get('result')}")
    if len(imported.get("scenes", [])) != 1:
        failures.append(f"OTIO import created scenes {imported.get('scenes')}")
    for name, strip in sorted(expected.items()):
        got = imported.get("strips", {}).get(name)
        if got != strip:
            failures.append(f"imported strip {name} is {got}, expected {strip}")
    return failures


VALIDATORS = {
    "gltf-bridges": validate_gltf_bridges,
    "ktx": validate_ktx,
    "otio": validate_otio,
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
