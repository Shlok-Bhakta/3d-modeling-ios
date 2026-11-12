#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
GHOST_INTERN = REPOSITORY / "intern" / "ghost" / "intern"
LATCH_HEADER = GHOST_INTERN / "GHOST_IOSModifierLatch.hh"
BELT_HEADER = GHOST_INTERN / "GHOST_IOSModifierBelt.hh"
BELT_SOURCE = GHOST_INTERN / "GHOST_IOSModifierBelt.mm"
WINDOW_SOURCE = GHOST_INTERN / "GHOST_WindowIOS.mm"
WINDOW_HEADER = GHOST_INTERN / "GHOST_WindowIOS.hh"
POINTER_SOURCE = GHOST_INTERN / "GHOST_IOSVirtualPointer.mm"
GHOST_CMAKE = REPOSITORY / "build_files" / "ios" / "cmake" / "ghost_ios.cmake"


def run_latch_harness(test: unittest.TestCase, body: str) -> None:
    """Compile a C++ program against the platform-neutral latch and run it."""
    harness = textwrap.dedent(
        """
        #include "GHOST_IOSModifierLatch.hh"

        #include <cstdio>
        #include <cstdlib>

        #define CHECK(expr) \\
          do { \\
            if (!(expr)) { \\
              std::fprintf(stderr, "%s:%d: CHECK(%s) failed\\n", __FILE__, __LINE__, #expr); \\
              std::exit(1); \\
            } \\
          } while (0)

        using Mod = GHOST_IOSModifier;
        using Mode = GHOST_IOSModifierMode;

        int main()
        {
        """
    ) + textwrap.indent(textwrap.dedent(body), "  ") + "\n  return 0;\n}\n"

    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        source = temporary / "modifier_latch_test.cc"
        executable = temporary / "modifier_latch_test"
        source.write_text(harness)
        compile_result = subprocess.run(
            ["xcrun", "clang++", "-std=c++17", "-Wall", "-Werror", "-I", str(GHOST_INTERN),
             str(source), "-o", str(executable)],
            capture_output=True,
            text=True,
        )
        test.assertEqual(compile_result.returncode, 0, compile_result.stderr)
        result = subprocess.run([str(executable)], capture_output=True, text=True)
        test.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class GhostModifierLatchTests(unittest.TestCase):
    def test_tap_applies_shift_to_the_next_click_only(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.keyDown(Mod::Shift, 1.00);
            latch.keyUp(Mod::Shift, 1.10);
            CHECK(latch.mode(Mod::Shift) == Mode::Latched);
            /* A latched modifier must not change navigation between clicks. */
            CHECK(!latch.wantsDown(Mod::Shift));

            latch.pointerPressed();
            CHECK(latch.wantsDown(Mod::Shift));
            latch.pointerReleased();
            CHECK(!latch.wantsDown(Mod::Shift));
            CHECK(latch.mode(Mod::Shift) == Mode::Off);

            latch.pointerPressed();
            CHECK(!latch.wantsDown(Mod::Shift));
            latch.pointerReleased();
            """,
        )

    def test_double_tap_locks_for_every_click_and_a_tap_unlocks(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.keyDown(Mod::Control, 1.00);
            latch.keyUp(Mod::Control, 1.05);
            latch.keyDown(Mod::Control, 1.20);
            latch.keyUp(Mod::Control, 1.25);
            CHECK(latch.mode(Mod::Control) == Mode::Locked);

            for (int i = 0; i < 3; i++) {
              latch.pointerPressed();
              CHECK(latch.wantsDown(Mod::Control));
              latch.pointerReleased();
              CHECK(!latch.wantsDown(Mod::Control));
              CHECK(latch.mode(Mod::Control) == Mode::Locked);
            }

            latch.keyDown(Mod::Control, 5.00);
            latch.keyUp(Mod::Control, 5.05);
            CHECK(latch.mode(Mod::Control) == Mode::Off);
            latch.pointerPressed();
            CHECK(!latch.wantsDown(Mod::Control));
            latch.pointerReleased();
            """,
        )

    def test_command_latches_alongside_control(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            GHOST_IOSModifierChange changes[GHOST_IOS_MODIFIER_COUNT];
            latch.keyDown(Mod::Control, 1.00);
            latch.keyUp(Mod::Control, 1.05);
            latch.keyDown(Mod::Command, 1.50);
            latch.keyUp(Mod::Command, 1.55);
            CHECK(latch.mode(Mod::Command) == Mode::Latched);
            CHECK(!latch.wantsDown(Mod::Command));

            latch.pointerPressed();
            CHECK(latch.takeChanges(changes) == 2);
            CHECK(changes[0].modifier == Mod::Control && changes[0].down);
            CHECK(changes[1].modifier == Mod::Command && changes[1].down);
            latch.pointerReleased();
            CHECK(latch.takeChanges(changes) == 2);
            CHECK(latch.mode(Mod::Command) == Mode::Off);
            """,
        )

    def test_slow_second_tap_clears_the_latch_instead_of_locking(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.keyDown(Mod::Alt, 1.00);
            latch.keyUp(Mod::Alt, 1.05);
            CHECK(latch.mode(Mod::Alt) == Mode::Latched);
            latch.keyDown(Mod::Alt, 3.00);
            latch.keyUp(Mod::Alt, 3.05);
            CHECK(latch.mode(Mod::Alt) == Mode::Off);
            """,
        )

    def test_holding_a_key_is_immediate_and_momentary(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.keyDown(Mod::Shift, 1.00);
            /* Holding works like a keyboard, including mid-drag snapping and precision. */
            CHECK(latch.wantsDown(Mod::Shift));
            CHECK(latch.mode(Mod::Shift) == Mode::Held);

            latch.pointerPressed();
            CHECK(latch.wantsDown(Mod::Shift));
            latch.pointerReleased();
            CHECK(latch.wantsDown(Mod::Shift));
            latch.pointerPressed();
            latch.pointerReleased();

            /* Even a quick release after clicking must not leave a latch behind. */
            latch.keyUp(Mod::Shift, 1.20);
            CHECK(!latch.wantsDown(Mod::Shift));
            CHECK(latch.mode(Mod::Shift) == Mode::Off);
            latch.pointerPressed();
            CHECK(!latch.wantsDown(Mod::Shift));
            latch.pointerReleased();
            """,
        )

    def test_long_hold_without_a_click_does_not_latch(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.keyDown(Mod::Shift, 1.00);
            latch.keyUp(Mod::Shift, 2.00);
            CHECK(latch.mode(Mod::Shift) == Mode::Off);
            CHECK(!latch.wantsDown(Mod::Shift));
            """,
        )

    def test_holding_a_locked_key_keeps_it_locked(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.keyDown(Mod::Shift, 1.00);
            latch.keyUp(Mod::Shift, 1.05);
            latch.keyDown(Mod::Shift, 1.15);
            latch.keyUp(Mod::Shift, 1.20);
            CHECK(latch.mode(Mod::Shift) == Mode::Locked);

            latch.keyDown(Mod::Shift, 4.00);
            latch.pointerPressed();
            latch.pointerReleased();
            latch.keyUp(Mod::Shift, 4.50);
            CHECK(latch.mode(Mod::Shift) == Mode::Locked);
            """,
        )

    def test_tapping_during_a_drag_applies_immediately_and_is_consumed_on_release(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.pointerPressed();
            latch.keyDown(Mod::Control, 1.00);
            latch.keyUp(Mod::Control, 1.05);
            CHECK(latch.mode(Mod::Control) == Mode::Latched);
            CHECK(latch.wantsDown(Mod::Control));
            latch.pointerReleased();
            CHECK(!latch.wantsDown(Mod::Control));
            CHECK(latch.mode(Mod::Control) == Mode::Off);
            """,
        )

    def test_modifiers_are_independent_and_combine(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            latch.keyDown(Mod::Shift, 1.00);
            latch.keyUp(Mod::Shift, 1.05);
            latch.keyDown(Mod::Control, 1.50);
            latch.keyUp(Mod::Control, 1.55);
            CHECK(latch.mode(Mod::Shift) == Mode::Latched);
            CHECK(latch.mode(Mod::Control) == Mode::Latched);
            CHECK(latch.mode(Mod::Alt) == Mode::Off);
            CHECK(latch.anyActive());

            latch.pointerPressed();
            CHECK(latch.wantsDown(Mod::Shift));
            CHECK(latch.wantsDown(Mod::Control));
            CHECK(!latch.wantsDown(Mod::Alt));
            latch.pointerReleased();
            CHECK(!latch.anyActive());
            """,
        )

    def test_changes_report_each_transition_once(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            GHOST_IOSModifierChange changes[GHOST_IOS_MODIFIER_COUNT];

            CHECK(latch.takeChanges(changes) == 0);
            latch.keyDown(Mod::Alt, 1.00);
            CHECK(latch.takeChanges(changes) == 1);
            CHECK(changes[0].modifier == Mod::Alt && changes[0].down);
            CHECK(latch.takeChanges(changes) == 0);

            latch.keyUp(Mod::Alt, 1.05);
            CHECK(latch.takeChanges(changes) == 1);
            CHECK(changes[0].modifier == Mod::Alt && !changes[0].down);

            /* The latch only presses around the click, then releases it. */
            latch.pointerPressed();
            CHECK(latch.takeChanges(changes) == 1);
            CHECK(changes[0].modifier == Mod::Alt && changes[0].down);
            latch.pointerReleased();
            CHECK(latch.takeChanges(changes) == 1);
            CHECK(changes[0].modifier == Mod::Alt && !changes[0].down);
            CHECK(latch.takeChanges(changes) == 0);
            """,
        )

    def test_external_release_is_pressed_again_and_cancel_drops_the_key(self) -> None:
        run_latch_harness(
            self,
            """
            GHOST_IOSModifierLatch latch;
            GHOST_IOSModifierChange changes[GHOST_IOS_MODIFIER_COUNT];

            latch.keyDown(Mod::Shift, 1.00);
            CHECK(latch.takeChanges(changes) == 1);
            /* App activation or a hardware snapshot released the key behind our back. */
            latch.forgetSent(Mod::Shift);
            CHECK(latch.takeChanges(changes) == 1);
            CHECK(changes[0].modifier == Mod::Shift && changes[0].down);

            latch.keyCancelled(Mod::Shift);
            CHECK(latch.mode(Mod::Shift) == Mode::Off);
            CHECK(latch.takeChanges(changes) == 1);
            CHECK(!changes[0].down);

            latch.keyDown(Mod::Control, 2.00);
            latch.keyUp(Mod::Control, 2.05);
            latch.clear();
            CHECK(!latch.anyActive());

            /* Clearing while a key is down in Blender still releases it. */
            latch.keyDown(Mod::Alt, 3.00);
            CHECK(latch.takeChanges(changes) == 1);
            latch.clear();
            CHECK(latch.takeChanges(changes) == 1);
            CHECK(changes[0].modifier == Mod::Alt && !changes[0].down);
            CHECK(latch.takeChanges(changes) == 0);
            """,
        )


class GhostModifierBeltIntegrationTests(unittest.TestCase):
    def test_belt_is_an_ios_ghost_shim_built_into_ghost(self) -> None:
        cmake = GHOST_CMAKE.read_text()
        self.assertIn("intern/GHOST_IOSModifierLatch.hh", cmake)
        self.assertIn("intern/GHOST_IOSModifierBelt.hh", cmake)
        self.assertIn("intern/GHOST_IOSModifierBelt.mm", cmake)

    def test_belt_keys_expose_state_for_ui_tests(self) -> None:
        source = BELT_SOURCE.read_text()
        for identifier in (
            "blender_modifier_belt",
            "blender_modifier_belt_handle",
            "blender_modifier_shift",
            "blender_modifier_control",
            "blender_modifier_alt",
            "blender_modifier_command",
        ):
            self.assertIn(identifier, source)
        self.assertIn("accessibilityValue", source)

    def test_command_key_sends_blenders_os_key(self) -> None:
        source = WINDOW_SOURCE.read_text()
        mapping = source[source.index("static GHOST_TModifierKey IOS_belt_modifier_key(") :]
        mapping = mapping[: mapping.index("\n}\n")]
        self.assertIn("case GHOST_IOSModifier::Command:\n      return GHOST_kModifierKeyLeftOS;",
                      mapping)
        self.assertIn('@"command", @"Cmd", @"blender_modifier_command"', BELT_SOURCE.read_text())

    def test_belt_moves_and_snaps_to_corners_and_remembers_the_corner(self) -> None:
        source = BELT_SOURCE.read_text()
        self.assertIn("UIPanGestureRecognizer", source)
        self.assertIn("GHOST_IOSModifierBeltCorner", source)
        self.assertIn("NSUserDefaults", source)
        self.assertIn("safeAreaLayoutGuide", source)

    def test_belt_hides_while_a_hardware_keyboard_is_connected(self) -> None:
        source = BELT_SOURCE.read_text()
        self.assertIn("GCKeyboardDidConnectNotification", source)
        self.assertIn("GCKeyboardDidDisconnectNotification", source)
        self.assertIn("GCKeyboard.coalescedKeyboard", source)

    def test_window_keeps_belt_touches_away_from_blender(self) -> None:
        source = WINDOW_SOURCE.read_text()
        should_receive = source[source.index("shouldReceiveTouch:(UITouch *)touch\n{") :]
        should_receive = should_receive[: should_receive.index("\n}\n")]
        self.assertIn("GHOST_IOSModifierBelt_containsView(modifier_belt, touch.view)", should_receive)
        send_event = source[source.index("- (void)sendEvent:(UIEvent *)event") :]
        send_event = send_event[: send_event.index("[super sendEvent:event];")]
        self.assertIn("GHOST_IOSModifierBelt_containsView(modifier_belt, touch.view)", send_event)

    def test_pointer_buttons_bracket_belt_modifiers(self) -> None:
        pointer = POINTER_SOURCE.read_text()
        send_button = pointer[pointer.index("void sendButtonEvent(") :]
        send_button = send_button[: send_button.index("\n  }\n")]
        before = send_button.index("modifierBeltPointerButton(true)")
        push = send_button.index("pushEvent")
        after = send_button.index("modifierBeltPointerButton(false)")
        self.assertLess(before, push, "modifiers must reach Blender before the press")
        self.assertLess(push, after, "modifiers must be released after the release")
        self.assertIn("modifierBeltPointerButton", WINDOW_HEADER.read_text())

    def test_hardware_pointer_snapshots_do_not_release_belt_modifiers(self) -> None:
        source = WINDOW_SOURCE.read_text()
        synchronize = source[source.index("- (void)synchronizePointerModifiers:(UIKeyModifierFlags)flags\n{") :]
        synchronize = synchronize[: synchronize.index("\n}\n")]
        self.assertIn("modifier_latch->sent(", synchronize)


if __name__ == "__main__":
    unittest.main()
