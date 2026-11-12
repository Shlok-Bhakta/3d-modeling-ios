#!/usr/bin/env python3
"""iPad keyboards need the same Command shortcuts as Blender on macOS.

Python reports ``ios`` on iPadOS, not ``darwin``, so the keymap presets must
treat both as Apple platforms. Each preset's real ``load()`` runs here against
a small ``bpy`` stand-in, and the keymap it would register is inspected.
"""

import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[3]
KEYCONFIG = REPOSITORY / "scripts" / "presets" / "keyconfig"
MODULES = REPOSITORY / "scripts" / "modules"
PRESETS = ("Blender", "Blender_27x", "Industry_Compatible")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def property_stub(**kwargs):
    return kwargs


def fake_bpy():
    bpy = types.ModuleType("bpy")
    bpy.props = types.SimpleNamespace(
        BoolProperty=property_stub,
        EnumProperty=property_stub,
    )
    bpy.types = types.SimpleNamespace(KeyConfigPreferences=object)
    bpy.utils = types.ModuleType("bpy.utils")
    bpy.utils.execfile = lambda path: load_module(Path(path).stem, path)
    bpy.utils.register_class = lambda _cls: None
    bpy.app = types.SimpleNamespace(translations=types.SimpleNamespace(contexts=mock.MagicMock()))
    translations = types.ModuleType("bpy.app.translations")
    translations.contexts = bpy.app.translations.contexts
    return bpy, translations


def generated_keymap(preset, platform):
    """Return the keymap data ``preset.load()`` registers on ``platform``."""
    bpy, translations = fake_bpy()
    captured = []
    io = types.ModuleType("bl_keymap_utils.io")
    io.keyconfig_init_from_data = lambda _kc, data: captured.append(data)

    modules = {
        "bpy": bpy,
        "bpy.props": bpy.props,
        "bpy.utils": bpy.utils,
        "bpy.app": bpy.app,
        "bpy.app.translations": translations,
        "bl_keymap_utils.io": io,
    }
    with mock.patch.dict(sys.modules, modules), \
            mock.patch.object(sys, "path", [str(MODULES)] + sys.path), \
            mock.patch.object(sys, "platform", platform):
        module = load_module(f"keyconfig_{preset}", KEYCONFIG / f"{preset}.py")
        defaults = {}
        prefs_class = getattr(module, "Prefs", None)
        for name, prop in getattr(prefs_class, "__annotations__", {}).items():
            defaults[name] = prop.get("default")
        keyconfig = types.SimpleNamespace(preferences=types.SimpleNamespace(**defaults))
        bpy.context = types.SimpleNamespace(
            preferences=types.SimpleNamespace(
                view=types.SimpleNamespace(show_developer_ui=False),
                inputs=types.SimpleNamespace(
                    use_mouse_emulate_3_button=False,
                    mouse_emulate_3_button_modifier='ALT',
                ),
            ),
            window_manager=types.SimpleNamespace(
                keyconfigs=types.SimpleNamespace(new=lambda _name: keyconfig),
            ),
        )
        module.load()
    assert len(captured) == 1
    return captured[0]


def bindings(keyconfig_data, keymap_name, operator):
    for name, _params, data in keyconfig_data:
        if name == keymap_name:
            return [event for op, event, _props in data["items"] if op == operator]
    raise AssertionError(f"{keymap_name} keymap is missing")


def uses(events, modifier, key):
    return any(event.get(modifier) and event["type"] == key for event in events)


class CommandKeymapTests(unittest.TestCase):
    def test_ios_adds_command_shortcuts_like_macos(self) -> None:
        for preset in PRESETS:
            with self.subTest(preset=preset):
                save = bindings(generated_keymap(preset, "ios"), "Window", "wm.save_mainfile")
                self.assertTrue(uses(save, "oskey", 'S'), "Cmd+S does not save on iPad")

    def test_ios_matches_macos_keymaps(self) -> None:
        for preset in PRESETS:
            with self.subTest(preset=preset):
                self.assertEqual(generated_keymap(preset, "ios"),
                                 generated_keymap(preset, "darwin"))

    def test_ios_keeps_control_shortcuts(self) -> None:
        keymap = generated_keymap("Blender", "ios")
        save = bindings(keymap, "Window", "wm.save_mainfile")
        select_linked = bindings(keymap, "Mesh", "mesh.select_linked")
        self.assertTrue(uses(save, "ctrl", 'S'))
        self.assertTrue(uses(select_linked, "ctrl", 'L'))
        self.assertTrue(uses(select_linked, "oskey", 'L'))

    def test_ios_leaves_system_command_shortcuts_alone(self) -> None:
        keymap = generated_keymap("Blender", "ios")
        for name, _params, data in keymap:
            for _op, event, _props in data["items"]:
                plain = not event.get("shift") and not event.get("alt")
                if event.get("oskey") and plain:
                    self.assertNotIn(event["type"], {'H', 'M', 'SPACE', 'W', 'TAB'}, name)

    def test_other_platforms_keep_control_only(self) -> None:
        save = bindings(generated_keymap("Blender", "linux"), "Window", "wm.save_mainfile")
        self.assertFalse(uses(save, "oskey", 'S'))


if __name__ == "__main__":
    unittest.main()
