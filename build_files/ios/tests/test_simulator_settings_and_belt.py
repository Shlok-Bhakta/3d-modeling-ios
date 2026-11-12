#!/usr/bin/env python3

"""Unit coverage for the pure parts of the settings and modifier belt harnesses."""

from pathlib import Path
import importlib.util
import json
import sys
import tempfile
import unittest


IOS = Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, IOS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


settings = load("simulator_settings_location")
belt = load("simulator_modifier_belt")


class SettingsHarnessTests(unittest.TestCase):
    def container(self, directory: str) -> Path:
        container = Path(directory)
        (container / "Documents" / "Settings" / "5.2" / "config").mkdir(parents=True)
        (container / "Documents" / "Settings" / "README.txt").write_text("readme")
        return container

    def report(self, container: Path, **extra) -> dict:
        report = {"user": str(container / "Documents" / "Settings" / "5.2"),
                  "previous_version": [], "can_load_previous": False}
        report.update(extra)
        return report

    def test_fresh_install_passes_and_reports_hidden_settings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            container = self.container(directory)
            self.assertEqual(settings.validate("fresh", container, self.report(container),
                                               "5.2", "5.1"), [])
            hidden = self.report(container, user=str(container / "Library" / "x" / "5.2"))
            self.assertTrue(settings.validate("fresh", container, hidden, "5.2", "5.1"))

    def test_leftover_legacy_folder_and_missing_readme_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            container = self.container(directory)
            (container / "Library" / "Application Support" / "Blender").mkdir(parents=True)
            (container / "Documents" / "Settings" / "README.txt").unlink()
            failures = settings.validate("fresh", container, self.report(container), "5.2", "5.1")
            self.assertEqual(len(failures), 2)

    def test_migration_requires_the_startup_script_to_run_from_settings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            container = self.container(directory)
            root = container / "Documents" / "Settings"
            (root / "5.2" / "config" / "bookmarks.txt").write_text("/settings-migration-sentinel")
            self.assertTrue(settings.validate("migrate", container, self.report(container),
                                              "5.2", "5.1"))
            script = root / "5.2" / "scripts" / "startup" / "settings_probe.py"
            (root / "probe-ran.json").write_text(json.dumps({"file": str(script)}))
            self.assertEqual(settings.validate("migrate", container, self.report(container),
                                               "5.2", "5.1"), [])

    def test_upgrade_requires_loading_previous_settings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            container = self.container(directory)
            (container / "Documents" / "Settings" / "5.1" / "config").mkdir(parents=True)
            (container / "Documents" / "Settings" / "5.1" / "config" / "userpref.blend").write_bytes(
                b"BLENDER")
            offered = self.report(container, previous_version=[5, 1], can_load_previous=True)
            self.assertEqual(settings.validate("upgrade", container,
                                               dict(offered, loaded_previous=True), "5.2", "5.1"),
                             [])
            self.assertTrue(settings.validate("upgrade", container, offered, "5.2", "5.1"))


class BeltHarnessTests(unittest.TestCase):
    def test_expected_clicks_and_corner_pass(self) -> None:
        self.assertEqual(belt.validate(list(belt.EXPECTED), belt.TOP_LEFT), [])

    def test_a_sticky_latch_or_wrong_corner_fails(self) -> None:
        events = [dict(event) for event in belt.EXPECTED]
        events[2]["shift"] = True
        self.assertEqual(len(belt.validate(events, 3)), 2)

    def test_element_centers_are_normalized(self) -> None:
        hierarchy = {
            "attributes": {"bounds": "[0,0][1000,2000]"},
            "children": [{"attributes": {"resource-id": "blender_modifier_shift",
                                         "bounds": "[100,200][300,400]"}}],
        }
        centers, screen = belt.element_centers(hierarchy)
        self.assertEqual(screen, (1000.0, 2000.0))
        self.assertEqual(centers, {"blender_modifier_shift": (0.2, 0.15)})

    def test_touch_segments_release_every_contact_and_stay_on_screen(self) -> None:
        centers = {identifier: (0.9, 0.9) for identifier in belt.BELT_IDS}
        segments = belt.touch_segments(centers)
        self.assertEqual(len(segments), 10)
        for segment in segments:
            down = 0
            for event in segment:
                if event.get("idle"):
                    continue
                self.assertTrue(all(0 <= c <= 1 for point in event["points"] for c in point))
                down += {1: 1, 2: -1, 6: 0}[event["phase"]]
                self.assertIn(down, (0, 1))
            self.assertEqual(down, 0)


if __name__ == "__main__":
    unittest.main()
