/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "BKE_context.hh"
#include "BLI_path_utils.hh"
#include "BLI_string.hh"
#include "BLI_utildefines.hh"
#include "BPY_extern_run.hh"

namespace blender {

void wm_init_ios_cycles_smoke(bContext *C)
{
  const char *requested_device = BLI_getenv("BLENDER_IOS_CYCLES_SMOKE");
  if (requested_device == nullptr) {
    return;
  }
  const bool use_metal = STREQ(requested_device, "METAL");

  /* Run only after startup scripts have registered the Cycles render engine. This exercises the
   * embedded module, CPU-device discovery, scene synchronization, TBB task runtime, CPU kernels,
   * and image output rather than treating a successful import as render acceptance. */
  const bool ok = BPY_run_string_exec(
      C,
      nullptr,
      "import bpy, _cycles, os, tempfile\n"
      "_ios_cycles_target = ('METAL' if "
      "os.environ.get('BLENDER_IOS_CYCLES_SMOKE', '').upper() == 'METAL' else 'CPU')\n"
      "_ios_cycles_devices = _cycles.available_devices("
      "_ios_cycles_target if _ios_cycles_target == 'METAL' else 'NONE')\n"
      "assert any(device[1] == _ios_cycles_target for device in _ios_cycles_devices), "
      "_ios_cycles_devices\n"
      "_ios_cycles_scene = bpy.context.scene\n"
      "_ios_cycles_preferences = None\n"
      "_ios_cycles_previous_compute_type = None\n"
      "_ios_cycles_previous_device_uses = []\n"
      "if _ios_cycles_target == 'METAL':\n"
      "    _ios_cycles_preferences = bpy.context.preferences.addons['cycles'].preferences\n"
      "    _ios_cycles_previous_compute_type = _ios_cycles_preferences.compute_device_type\n"
      "    _ios_cycles_preferences.compute_device_type = 'METAL'\n"
      "    _ios_cycles_metal_devices = _ios_cycles_preferences.get_devices_for_type('METAL')\n"
      "    _ios_cycles_previous_device_uses = [(device, device.use) "
      "for device in _ios_cycles_metal_devices]\n"
      "    for device in _ios_cycles_metal_devices:\n"
      "        device.use = (device.type == 'METAL')\n"
      "_ios_cycles_previous = (\n"
      "    _ios_cycles_scene.render.engine,\n"
      "    _ios_cycles_scene.render.resolution_x,\n"
      "    _ios_cycles_scene.render.resolution_y,\n"
      "    _ios_cycles_scene.render.resolution_percentage,\n"
      "    _ios_cycles_scene.render.filepath,\n"
      "    _ios_cycles_scene.render.image_settings.file_format,\n"
      "    _ios_cycles_scene.cycles.device,\n"
      "    _ios_cycles_scene.cycles.samples,\n"
      "    _ios_cycles_scene.cycles.use_adaptive_sampling,\n"
      "    _ios_cycles_scene.cycles.use_denoising,\n"
      ")\n"
      "_ios_cycles_path = os.path.join(tempfile.gettempdir(), 'blender-ios-cycles-smoke.png')\n"
      "try:\n"
      "    _ios_cycles_scene.render.engine = 'CYCLES'\n"
      "    _ios_cycles_scene.cycles.device = "
      "('GPU' if _ios_cycles_target == 'METAL' else 'CPU')\n"
      "    _ios_cycles_scene.cycles.samples = 1\n"
      "    _ios_cycles_scene.cycles.use_adaptive_sampling = False\n"
      "    _ios_cycles_scene.cycles.use_denoising = False\n"
      "    _ios_cycles_scene.render.resolution_x = 8\n"
      "    _ios_cycles_scene.render.resolution_y = 8\n"
      "    _ios_cycles_scene.render.resolution_percentage = 100\n"
      "    _ios_cycles_scene.render.filepath = _ios_cycles_path\n"
      "    _ios_cycles_scene.render.image_settings.file_format = 'PNG'\n"
      "    assert bpy.ops.render.render(write_still=True) == {'FINISHED'}\n"
      "    assert os.path.getsize(_ios_cycles_path) > 64\n"
      "finally:\n"
      "    if os.path.exists(_ios_cycles_path):\n"
      "        os.remove(_ios_cycles_path)\n"
      "    (_ios_cycles_scene.render.engine,\n"
      "     _ios_cycles_scene.render.resolution_x,\n"
      "     _ios_cycles_scene.render.resolution_y,\n"
      "     _ios_cycles_scene.render.resolution_percentage,\n"
      "     _ios_cycles_scene.render.filepath,\n"
      "     _ios_cycles_scene.render.image_settings.file_format,\n"
      "     _ios_cycles_scene.cycles.device,\n"
      "     _ios_cycles_scene.cycles.samples,\n"
      "     _ios_cycles_scene.cycles.use_adaptive_sampling,\n"
      "     _ios_cycles_scene.cycles.use_denoising) = _ios_cycles_previous\n"
      "    for device, previous_use in _ios_cycles_previous_device_uses:\n"
      "        device.use = previous_use\n"
      "    if _ios_cycles_preferences is not None:\n"
      "        _ios_cycles_preferences.compute_device_type = _ios_cycles_previous_compute_type\n"
      "    if _ios_cycles_target == 'METAL':\n"
      "        del _ios_cycles_metal_devices\n"
      "del _ios_cycles_devices, _ios_cycles_path, _ios_cycles_previous, _ios_cycles_scene\n"
      "del _ios_cycles_preferences, _ios_cycles_previous_compute_type\n"
      "del _ios_cycles_previous_device_uses\n"
      "del _ios_cycles_target\n");

  if (ok) {
    fprintf(stderr,
            "BLENDER_IOS_CYCLES_READY=%s-render\n",
            use_metal ? "metal" : "cpu");
  }
  else {
    fprintf(stderr, "BLENDER_IOS_CYCLES_FAILED\n");
  }
}

}  // namespace blender
