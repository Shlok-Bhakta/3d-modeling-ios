#!/usr/bin/env python3

from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
WINDOW_SOURCE = REPOSITORY / "intern" / "ghost" / "intern" / "GHOST_WindowIOS.mm"
INTERFACE_SOURCE = (
    REPOSITORY / "source" / "blender" / "editors" / "interface" / "interface_handlers.cc"
)


class IOSOnscreenKeyboardTests(unittest.TestCase):
    def test_text_editing_opens_and_closes_the_native_keyboard(self) -> None:
        source = INTERFACE_SOURCE.read_text()
        begin = source[source.index("static void textedit_begin(") : source.index("static void textedit_end(")]
        end = source[source.index("static void textedit_end(") : source.index("static void textedit_next_but(")]

        self.assertIn("popupOnScreenKeyboard", begin)
        self.assertIn("text_box_origin", begin)
        self.assertIn("text_edit.edit_string", begin)
        self.assertIn("hideOnScreenKeyboard", end)
        self.assertIn("getKeyboardInput", end)
        self.assertIn("textedit_string_set", end)

    def test_every_blender_field_uses_the_full_expression_keyboard(self) -> None:
        source = WINDOW_SOURCE.read_text()
        setup = source[
            source.rindex("- (void)setupKeyboard:") : source.rindex("- (const GHOST_TabletData)")
        ]

        self.assertIn("text_field.keyboardType = UIKeyboardTypeDefault;", setup)
        self.assertNotIn("UIKeyboardTypeDecimalPad", setup)
        self.assertNotIn("UIKeyboardTypeNumberPad", setup)
        self.assertIn("text_field.autocorrectionType = UITextAutocorrectionTypeNo;", setup)

    def test_done_emits_a_balanced_enter_key(self) -> None:
        source = WINDOW_SOURCE.read_text()
        handler = source[
            source.index("- (void)generateKeyboardReturnEvent") : source.index(
                "- (void)handleKeyboardReturn:"
            )
        ]

        self.assertIn("GHOST_kEventKeyDown", handler)
        self.assertIn("GHOST_kEventKeyUp", handler)
        self.assertIn("notifyExternalEventProcessed", handler)

    def test_keyboard_accessory_actions_target_the_ios_window(self) -> None:
        source = WINDOW_SOURCE.read_text()
        toolbar = source[source.rindex("- (void)initToolbar") : source.rindex("- (void)generateKeyboardReturnEvent")]

        self.assertGreaterEqual(toolbar.count("target:self"), 2)
        self.assertIn("@selector(handleDoneButton)", toolbar)
        self.assertIn("@selector(handleCancelButton)", toolbar)

    def test_initial_selection_is_restored_after_responder_activation(self) -> None:
        source = WINDOW_SOURCE.read_text()
        popup = source[
            source.rindex("- (GHOST_TSuccess)popupOnscreenKeyboard:") : source.rindex(
                "- (GHOST_TSuccess)hideOnscreenKeyboard"
            )
        ]

        self.assertIn("applyKeyboardSelection", popup)
        self.assertLess(popup.index("becomeFirstResponder"), popup.index("applyKeyboardSelection"))

    def test_committed_text_survives_clearing_the_native_field(self) -> None:
        source = WINDOW_SOURCE.read_text()
        getter = source[
            source.rindex("- (const char *)getLastKeyboardString") : source.rindex("@end")
        ]

        self.assertIn("if (onscreen_keyboard_active && text_field.text != nil)", getter)

    def test_hardware_edits_are_not_replaced_by_the_native_copy(self) -> None:
        # #69: hardware keys edit Blender's string, so Return must not commit the native field's
        # unchanged text. The runtime check is `simulator_hardware_input.py --case text-return`.
        source = WINDOW_SOURCE.read_text()
        hardware = source[
            source.rindex("- (void)generateHardwareKeyEvents:") : source.rindex(
                "- (void)synchronizePointerModifiers:"
            )
        ]
        setup = source[
            source.rindex("- (void)setupKeyboard:") : source.rindex("- (void)applyKeyboardSelection:")
        ]
        getter = source[
            source.rindex("- (const char *)getLastKeyboardString") : source.rindex("@end")
        ]

        self.assertIn("if (is_down && onscreen_keyboard_active) {\n      text_field_stale = true;", hardware)
        self.assertIn("text_field_stale = false;", setup)
        self.assertLess(getter.index("if (text_field_stale) {\n      return nullptr;"),
                        getter.index("text_field.text UTF8String"))

    def test_native_edits_are_forwarded_to_blender_while_typing(self) -> None:
        source = WINDOW_SOURCE.read_text()
        interface = source[
            source.index("@interface GHOSTUIWindow") : source.index("@implementation GHOSTUIWindow")
        ]
        init = source[
            source.rindex("- (void)initUITextField") : source.rindex(
                "- (UITextField *)getUITextField"
            )
        ]
        delegate = source[
            source.index("- (BOOL)textField:") : source.index("- (void)handleKeyboardEditChange:")
        ]

        self.assertIn("UITextFieldDelegate", interface)
        self.assertIn("text_field.delegate = self;", init)
        self.assertIn("GHOST_kKeyBackSpace", delegate)
        self.assertIn("GHOST_kKeyUnknown", delegate)
        self.assertGreaterEqual(delegate.count("generateKeyEvent"), 4)
        key_events = source[
            source.rindex(
                "- (void)generateKeyEvent:(GHOST_TKey)key down:(bool)is_down utf8:(const char *)utf8\n{"
            ) : source.rindex("- (void)generateHardwareKeyEvents:")
        ]
        self.assertIn("notifyExternalEventProcessed", key_events)


if __name__ == "__main__":
    unittest.main()
