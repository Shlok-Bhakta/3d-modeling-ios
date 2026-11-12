/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/* GHOST's cross-platform C++ interfaces intentionally do not carry Objective-C
 * nullability qualifiers. UIKit makes Clang request them for every pointer. */
#pragma clang diagnostic ignored "-Wnullability-completeness"

#include "GHOST_WindowIOS.hh"

#include "GHOST_ContextIOS.hh"
#include "GHOST_IOSFileAccess.hh"
#include "GHOST_IOSInputTuning.hh"
#include "GHOST_IOSModifierBelt.hh"
#include "GHOST_IOSModifierLatch.hh"
#include "GHOST_IOSPencilContact.hh"
#include "GHOST_IOSVirtualPointer.hh"
#include "GHOST_SystemIOS.hh"

#include "GHOST_Debug.hh"
#include "GHOST_EventDragnDrop.hh"
#include "GHOST_EventKey.hh"
#include "GHOST_EventTouch.hh"
#include "GHOST_EventTrackpad.hh"
#include "GHOST_EventWheel.hh"
#include "GHOST_WindowManager.hh"

#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIPencilInteraction.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <unordered_map>

// #define IOS_INPUT_LOGGING
#if defined(IOS_INPUT_LOGGING)
#  define IOS_INPUT_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_INPUT_LOG(...)
#endif

// #define IOS_WINDOW_LOGGING
#if defined(IOS_WINDOW_LOGGING)
#  define IOS_WINDOW_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_WINDOW_LOG(...)
#endif

struct TouchData {
  CGPoint pos;
  bool part_of_multitouch = false;
};

typedef struct UserInputEvent {
  enum EventTypes {
    PAN_GESTURE_TWO_FINGERS,
    PAN_GESTURE_THREE_FINGERS,
    POINTER_SCROLL,
    PINCH_GESTURE,
  };
  EventTypes event_list[10];
  int num_events;
  CGPoint location;
  CGPoint translation;
  CGFloat distance;

  UserInputEvent(CGPoint *loc, CGPoint *tran, CGFloat *dist)
  {
    num_events = 0;
    location = loc ? *loc : CGPointMake(-1.0f, -1.0f);
    translation = tran ? *tran : CGPointMake(0.0f, 0.0f);
    distance = dist ? *dist : 0.0f;
  }

  void add_event(EventTypes event_type)
  {
    GHOST_ASSERT(num_events < sizeof(event_list) / sizeof(*event_list),
                 "add_event: Failed to add event");
    event_list[num_events] = event_type;
    num_events++;
  }

  NSString *getEventTypeDesc(EventTypes event_type) const
  {
    switch (event_type) {
      case PAN_GESTURE_TWO_FINGERS:
        return @"PAN2F";
      case PAN_GESTURE_THREE_FINGERS:
        return @"PAN3F";
      case POINTER_SCROLL:
        return @"SCROLL";
      case PINCH_GESTURE:
        return @"PINCH";
    }
    BLI_assert_unreachable();
    return @"Event undefined";
  }

} UserInputEvent;


/* GHOSTUITapGesture interface for capturing taps. */
@interface GHOSTUITapGestureRecognizer : UITapGestureRecognizer
{
  CGPoint first_tap_point;
  BOOL has_first_tap_point;
  UITouchType touch_type;
}

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
- (CGPoint)getScaledFirstTapPoint:(GHOST_WindowIOS *)window;
- (UITouchType)getTouchType;
- (void)resetFirstTapPoint;

@end

@implementation GHOSTUITapGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  UITouch *touch = [touches anyObject];
  touch_type = touch != nil ? touch.type : UITouchTypeDirect;
  if (self.numberOfTapsRequired > 1 && touch.tapCount == 1) {
    first_tap_point = [touch locationInView:self.view];
    has_first_tap_point = YES;
  }
  [super touchesBegan:touches withEvent:event];
}

- (UITouchType)getTouchType
{
  return touch_type;
}

- (CGPoint)getScaledFirstTapPoint:(GHOST_WindowIOS *)window
{
  if (!has_first_tap_point) {
    return [self getScaledTouchPoint:window];
  }
  return window->scalePointToWindow(first_tap_point);
}

- (void)resetFirstTapPoint
{
  has_first_tap_point = NO;
}

@end

@interface GHOSTUILongPressGestureRecognizer : UILongPressGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
@end

@implementation GHOSTUILongPressGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint point = [self locationInView:window->getView()];
  return window->scalePointToWindow(point);
}

@end

/* GHOSTUITapGesture interface for capturing taps. */
@interface GHOSTUIPanGestureRecognizer : UIPanGestureRecognizer
{
  CGPoint cached_translation;
  CGPoint initial_touch_point;
  BOOL has_initial_touch_point;
  NSTimeInterval initial_touch_timestamp;
  NSTimeInterval touch_timestamp;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
- (CGPoint)getScaledInitialTouchPoint:(GHOST_WindowIOS *)window;
- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window;
- (CGPoint)getRelativeTranslation:(CGPoint)translation;
- (NSTimeInterval)getInitialTouchTimestamp;
- (NSTimeInterval)getTouchTimestamp;

- (void)setCachedTranslation:(CGPoint)translation;
- (CGPoint)getCachedTranslation;
@end

@implementation GHOSTUIPanGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  if (self.minimumNumberOfTouches == 1 && self.maximumNumberOfTouches == 1) {
    UITouch *touch = [touches anyObject];
    initial_touch_point = [touch locationInView:self.view];
    initial_touch_timestamp = touch.timestamp;
    touch_timestamp = touch.timestamp;
    has_initial_touch_point = YES;
  }
  [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  UITouch *touch = [touches anyObject];
  if (touch != nil) {
    touch_timestamp = touch.timestamp;
  }
  [super touchesMoved:touches withEvent:event];
}

- (CGPoint)getScaledInitialTouchPoint:(GHOST_WindowIOS *)window
{
  if (!has_initial_touch_point) {
    return [self getScaledTouchPoint:window];
  }
  return window->scalePointToWindow(initial_touch_point);
}

- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window
{
  CGPoint translation = [self translationInView:window->getView()];
  return window->scalePointToWindow(translation);
}

- (CGPoint)getRelativeTranslation:(CGPoint)translation
{
  CGPoint relative_translation;
  relative_translation.x = translation.x - cached_translation.x;
  relative_translation.y = translation.y - cached_translation.y;
  return relative_translation;
}

- (NSTimeInterval)getInitialTouchTimestamp
{
  return initial_touch_timestamp;
}

- (NSTimeInterval)getTouchTimestamp
{
  return touch_timestamp;
}

- (void)setCachedTranslation:(CGPoint)translation
{
  cached_translation = translation;
}

- (CGPoint)getCachedTranslation
{
  return cached_translation;
}

@end

@interface GHOSTUIHoverGestureRecognizer : UIHoverGestureRecognizer
{
  UITouchType hover_touch_type;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
- (UITouchType)getTouchType;
@end

@implementation GHOSTUIHoverGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  UITouch *touch = [touches anyObject];
  hover_touch_type = touch != nil ? touch.type : UITouchTypeIndirectPointer;
  [super touchesBegan:touches withEvent:event];
}

- (UITouchType)getTouchType
{
  return hover_touch_type;
}
@end

@interface GHOSTUIPinchGestureRecognizer : UIPinchGestureRecognizer
{
  CGFloat cached_distance;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id;
- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window;
- (void)setCachedDistance:(CGFloat)distance;
- (CGFloat)getCachedDistance;
@end

@implementation GHOSTUIPinchGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id
{
  CGPoint touch_point = [self locationOfTouch:touch_id inView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window
{
  CGPoint touch_point0 = [self locationOfTouch:0 inView:window->getView()];
  CGPoint touch_point1 = [self locationOfTouch:1 inView:window->getView()];
  touch_point0 = window->scalePointToWindow(touch_point0);
  touch_point1 = window->scalePointToWindow(touch_point1);
  float dx = touch_point1.x - touch_point0.x;
  float dy = touch_point1.y - touch_point0.y;
  CGFloat point_distance = sqrt(dx * dx + dy * dy);
  return point_distance;
}

- (void)setCachedDistance:(CGFloat)distance
{
  cached_distance = distance;
}

- (CGFloat)getCachedDistance
{
  return cached_distance;
}
@end

/* GHOSTUIWindow interface. */
@interface GHOSTUIWindow : UIWindow <UIGestureRecognizerDelegate,
                                      UIPencilInteractionDelegate,
                                      UITextFieldDelegate,
                                      GHOSTIOSModifierBeltDelegate>
{
  GHOST_SystemIOS *system;
  GHOST_WindowIOS *window;
  GHOST_IOSVirtualPointer *virtual_pointer;

  GHOSTUITapGestureRecognizer *tap_gesture_recognizer;
  GHOSTUILongPressGestureRecognizer *double_tap_drag_gesture_recognizer;
  GHOSTUITapGestureRecognizer *triple_tap_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap2f_gesture_recognizer;
  GHOSTUILongPressGestureRecognizer *two_finger_hold_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap3f_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap4f_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pencil_drag_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan2f_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan3f_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *scroll_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *wheel_gesture_recognizer;
  GHOSTUIPinchGestureRecognizer *zoom_gesture_recognizer;
  GHOSTUIHoverGestureRecognizer *hover_gesture_recognizer;
  bool two_finger_hold_active;
  UIPencilInteraction *pencil_interaction;
  UIScreenEdgePanGestureRecognizer *edge_swipe_left;
  UIScreenEdgePanGestureRecognizer *edge_swipe_right;
  // GHOSTUILongPressGestureRecognizer *long_press_gesture_recognizer;

  /* Data from the Apple pencil */
  UITouch *current_pencil_touch;
  GHOST_TabletData tablet_data;
  GHOST_IOSPencilContact pencil_contact;

  /* Keyboard handling. */
  UITextField *text_field;
  NSString *original_text;
  bool onscreen_keyboard_active;
  /* Hardware keys edit Blender's string directly, leaving the native field's copy out of date. */
  bool text_field_stale;
  std::string text_field_string;

  /* Toolbar */
  bool toolbar_enabled;
  UIToolbar *toolbar;
  UILabel *toolbar_tip_label;
  UILabel *toolbar_value_label;
  UIStackView *toolbar_text_stack;
  UIBarButtonItem *toolbar_text_item;
  UIBarButtonItem *toolbar_flexible_space_item;
  UIBarButtonItem *toolbar_done_editing_item;
  UIBarButtonItem *toolbar_cancel_editing_item;

  /* Native controls for Blender child windows. */
  UIButton *close_window_button;
  NSObject *file_access_controls;

  /* On-screen Shift, Ctrl, Alt and Cmd. */
  NSObject *modifier_belt;
  GHOST_IOSModifierLatch *modifier_latch;
}

- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sysCocoa windowIOS:(GHOST_WindowIOS *)winCocoa;

/* Window controls. */
- (void)registerWindowControls;
- (void)registerModifierBelt;
- (void)modifierBeltPointerButton:(bool)pressed;
- (void)modifierBeltCursorMoved:(CGPoint)point visible:(bool)visible;
- (void)updateFileAccessControls;
- (void)handleCloseWindow;
- (BOOL)allowsPointerLock;

/* Blender event generation. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info;

/* Gesture recognizers. */
- (void)registerGestureRecognizers;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch;
- (CGPoint)getVirtualPointerPoint;
- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender;
- (void)handleTripleTap:(GHOSTUITapGestureRecognizer *)sender;
- (void)handleDoubleTapDrag:(GHOSTUILongPressGestureRecognizer *)sender;
- (void)handleTwoFingerHold:(GHOSTUILongPressGestureRecognizer *)sender;
- (void)handleTap2F:(GHOSTUITapGestureRecognizer *)sender;
- (void)handleTap3F:(GHOSTUITapGestureRecognizer *)sender;
- (void)handleTap4F:(GHOSTUITapGestureRecognizer *)sender;
- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handlePencilDrag:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handlePan3f:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handlePointerScroll:(GHOSTUIPanGestureRecognizer *)sender;
- (void)synchronizePointerModifiers:(UIKeyModifierFlags)flags;
- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender;
- (void)updateTabletDataFromTouch:(UITouch *)touch;
- (void)resetTabletData;

/* On screen keyboard handling */
- (UITextField *)getUITextField;
- (const GHOST_TabletData)getTabletData;
- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties;
- (GHOST_TSuccess)hideOnscreenKeyboard;
- (const char *)getLastKeyboardString;
- (void)applyKeyboardSelection:(const GHOST_KeyboardProperties &)keyboard_properties;
- (void)generateKeyboardReturnEvent;
- (void)generateKeyboardCompletionEvent:(GHOST_TKey)key;
- (void)invalidateInput;
- (void)generateKeyEvent:(GHOST_TKey)key down:(bool)is_down utf8:(const char *)utf8;
- (void)generateUndoRedoShortcut:(bool)redo;
- (void)generateHardwareKeyEvents:(NSSet<UIPress *> *)presses type:(GHOST_TEventType)event_type;
@end

static GHOST_TKey convertKeyboardHIDUsage(const UIKeyboardHIDUsage usage)
{
  if (usage >= UIKeyboardHIDUsageKeyboardA && usage <= UIKeyboardHIDUsageKeyboardZ) {
    return static_cast<GHOST_TKey>(static_cast<int>(GHOST_kKeyA) + static_cast<int>(usage) -
                                   static_cast<int>(UIKeyboardHIDUsageKeyboardA));
  }
  if (usage >= UIKeyboardHIDUsageKeyboard1 && usage <= UIKeyboardHIDUsageKeyboard9) {
    return static_cast<GHOST_TKey>(static_cast<int>(GHOST_kKey1) + static_cast<int>(usage) -
                                   static_cast<int>(UIKeyboardHIDUsageKeyboard1));
  }
  if (usage >= UIKeyboardHIDUsageKeyboardF1 && usage <= UIKeyboardHIDUsageKeyboardF12) {
    return static_cast<GHOST_TKey>(static_cast<int>(GHOST_kKeyF1) + static_cast<int>(usage) -
                                   static_cast<int>(UIKeyboardHIDUsageKeyboardF1));
  }
  if (usage >= UIKeyboardHIDUsageKeyboardF13 && usage <= UIKeyboardHIDUsageKeyboardF24) {
    return static_cast<GHOST_TKey>(static_cast<int>(GHOST_kKeyF13) + static_cast<int>(usage) -
                                   static_cast<int>(UIKeyboardHIDUsageKeyboardF13));
  }
  if (usage >= UIKeyboardHIDUsageKeypad1 && usage <= UIKeyboardHIDUsageKeypad9) {
    return static_cast<GHOST_TKey>(static_cast<int>(GHOST_kKeyNumpad1) +
                                   static_cast<int>(usage) -
                                   static_cast<int>(UIKeyboardHIDUsageKeypad1));
  }

  switch (usage) {
    case UIKeyboardHIDUsageKeyboard0:
      return GHOST_kKey0;
    case UIKeyboardHIDUsageKeyboardReturnOrEnter:
      return GHOST_kKeyEnter;
    case UIKeyboardHIDUsageKeyboardEscape:
      return GHOST_kKeyEsc;
    case UIKeyboardHIDUsageKeyboardDeleteOrBackspace:
      return GHOST_kKeyBackSpace;
    case UIKeyboardHIDUsageKeyboardTab:
      return GHOST_kKeyTab;
    case UIKeyboardHIDUsageKeyboardSpacebar:
      return GHOST_kKeySpace;
    case UIKeyboardHIDUsageKeyboardHyphen:
      return GHOST_kKeyMinus;
    case UIKeyboardHIDUsageKeyboardEqualSign:
      return GHOST_kKeyEqual;
    case UIKeyboardHIDUsageKeyboardOpenBracket:
      return GHOST_kKeyLeftBracket;
    case UIKeyboardHIDUsageKeyboardCloseBracket:
      return GHOST_kKeyRightBracket;
    case UIKeyboardHIDUsageKeyboardBackslash:
    case UIKeyboardHIDUsageKeyboardNonUSBackslash:
      return GHOST_kKeyBackslash;
    case UIKeyboardHIDUsageKeyboardSemicolon:
      return GHOST_kKeySemicolon;
    case UIKeyboardHIDUsageKeyboardQuote:
      return GHOST_kKeyQuote;
    case UIKeyboardHIDUsageKeyboardGraveAccentAndTilde:
      return GHOST_kKeyAccentGrave;
    case UIKeyboardHIDUsageKeyboardComma:
      return GHOST_kKeyComma;
    case UIKeyboardHIDUsageKeyboardPeriod:
      return GHOST_kKeyPeriod;
    case UIKeyboardHIDUsageKeyboardSlash:
      return GHOST_kKeySlash;
    case UIKeyboardHIDUsageKeyboardCapsLock:
      return GHOST_kKeyCapsLock;
    case UIKeyboardHIDUsageKeyboardPrintScreen:
      return GHOST_kKeyPrintScreen;
    case UIKeyboardHIDUsageKeyboardScrollLock:
      return GHOST_kKeyScrollLock;
    case UIKeyboardHIDUsageKeyboardPause:
      return GHOST_kKeyPause;
    case UIKeyboardHIDUsageKeyboardInsert:
      return GHOST_kKeyInsert;
    case UIKeyboardHIDUsageKeyboardHome:
      return GHOST_kKeyHome;
    case UIKeyboardHIDUsageKeyboardPageUp:
      return GHOST_kKeyUpPage;
    case UIKeyboardHIDUsageKeyboardDeleteForward:
      return GHOST_kKeyDelete;
    case UIKeyboardHIDUsageKeyboardEnd:
      return GHOST_kKeyEnd;
    case UIKeyboardHIDUsageKeyboardPageDown:
      return GHOST_kKeyDownPage;
    case UIKeyboardHIDUsageKeyboardRightArrow:
      return GHOST_kKeyRightArrow;
    case UIKeyboardHIDUsageKeyboardLeftArrow:
      return GHOST_kKeyLeftArrow;
    case UIKeyboardHIDUsageKeyboardDownArrow:
      return GHOST_kKeyDownArrow;
    case UIKeyboardHIDUsageKeyboardUpArrow:
      return GHOST_kKeyUpArrow;
    case UIKeyboardHIDUsageKeypadNumLock:
      return GHOST_kKeyNumLock;
    case UIKeyboardHIDUsageKeypadSlash:
      return GHOST_kKeyNumpadSlash;
    case UIKeyboardHIDUsageKeypadAsterisk:
      return GHOST_kKeyNumpadAsterisk;
    case UIKeyboardHIDUsageKeypadHyphen:
      return GHOST_kKeyNumpadMinus;
    case UIKeyboardHIDUsageKeypadPlus:
      return GHOST_kKeyNumpadPlus;
    case UIKeyboardHIDUsageKeypadEnter:
      return GHOST_kKeyNumpadEnter;
    case UIKeyboardHIDUsageKeypad0:
      return GHOST_kKeyNumpad0;
    case UIKeyboardHIDUsageKeypadPeriod:
      return GHOST_kKeyNumpadPeriod;
    case UIKeyboardHIDUsageKeyboardApplication:
      return GHOST_kKeyApp;
    case UIKeyboardHIDUsageKeyboardLeftControl:
      return GHOST_kKeyLeftControl;
    case UIKeyboardHIDUsageKeyboardLeftShift:
      return GHOST_kKeyLeftShift;
    case UIKeyboardHIDUsageKeyboardLeftAlt:
      return GHOST_kKeyLeftAlt;
    case UIKeyboardHIDUsageKeyboardLeftGUI:
      return GHOST_kKeyLeftOS;
    case UIKeyboardHIDUsageKeyboardRightControl:
      return GHOST_kKeyRightControl;
    case UIKeyboardHIDUsageKeyboardRightShift:
      return GHOST_kKeyRightShift;
    case UIKeyboardHIDUsageKeyboardRightAlt:
      return GHOST_kKeyRightAlt;
    case UIKeyboardHIDUsageKeyboardRightGUI:
      return GHOST_kKeyRightOS;
    default:
      return GHOST_kKeyUnknown;
  }
}

static bool modifierForKey(const GHOST_TKey key, GHOST_TModifierKey &modifier)
{
  switch (key) {
    case GHOST_kKeyLeftShift:
      modifier = GHOST_kModifierKeyLeftShift;
      return true;
    case GHOST_kKeyRightShift:
      modifier = GHOST_kModifierKeyRightShift;
      return true;
    case GHOST_kKeyLeftControl:
      modifier = GHOST_kModifierKeyLeftControl;
      return true;
    case GHOST_kKeyRightControl:
      modifier = GHOST_kModifierKeyRightControl;
      return true;
    case GHOST_kKeyLeftAlt:
      modifier = GHOST_kModifierKeyLeftAlt;
      return true;
    case GHOST_kKeyRightAlt:
      modifier = GHOST_kModifierKeyRightAlt;
      return true;
    case GHOST_kKeyLeftOS:
      modifier = GHOST_kModifierKeyLeftOS;
      return true;
    case GHOST_kKeyRightOS:
      modifier = GHOST_kModifierKeyRightOS;
      return true;
    default:
      return false;
  }
}

@implementation GHOSTUIWindow
- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sys windowIOS:(GHOST_WindowIOS *)win
{
  system = sys;
  window = win;
  virtual_pointer = system->virtualPointer();
  text_field = nil;
  original_text = nil;
  onscreen_keyboard_active = false;
  text_field_stale = false;
  text_field_string.clear();
  current_pencil_touch = nil;
  tablet_data = GHOST_TABLET_DATA_NONE;
  two_finger_hold_active = false;
  toolbar_enabled = true;
  toolbar = nil;
  close_window_button = nil;
  file_access_controls = nil;
  modifier_belt = nil;
  modifier_latch = new GHOST_IOSModifierLatch();
}

- (void)releaseGestureRecognizer:(UIGestureRecognizer *)recognizer fromView:(UIView *)view
{
  if (recognizer == nil) {
    return;
  }
  recognizer.delegate = nil;
  [view removeGestureRecognizer:recognizer];
  [recognizer release];
}

- (void)invalidateInput
{
  UIView *input_view = window != nullptr ? window->getView() : nil;
  /* Resigning the text field synchronously calls its edit-end target. */
  onscreen_keyboard_active = false;

  GHOST_IOSFileAccess_destroyControls(file_access_controls);
  file_access_controls = nil;

  GHOST_IOSModifierBelt_destroy(modifier_belt);
  modifier_belt = nil;
  delete modifier_latch;
  modifier_latch = nullptr;

  if (close_window_button != nil) {
    [close_window_button removeTarget:self
                               action:@selector(handleCloseWindow)
                     forControlEvents:UIControlEventTouchUpInside];
    [close_window_button removeFromSuperview];
    [close_window_button release];
    close_window_button = nil;
  }

  [self releaseGestureRecognizer:tap_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:double_tap_drag_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:triple_tap_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:tap2f_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:two_finger_hold_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:tap3f_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:tap4f_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:pan_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:pencil_drag_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:pan2f_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:pan3f_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:scroll_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:wheel_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:zoom_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:hover_gesture_recognizer fromView:input_view];
  [self releaseGestureRecognizer:edge_swipe_left fromView:input_view];
  [self releaseGestureRecognizer:edge_swipe_right fromView:input_view];
  tap_gesture_recognizer = nil;
  double_tap_drag_gesture_recognizer = nil;
  triple_tap_gesture_recognizer = nil;
  tap2f_gesture_recognizer = nil;
  two_finger_hold_gesture_recognizer = nil;
  tap3f_gesture_recognizer = nil;
  tap4f_gesture_recognizer = nil;
  pan_gesture_recognizer = nil;
  pencil_drag_gesture_recognizer = nil;
  pan2f_gesture_recognizer = nil;
  pan3f_gesture_recognizer = nil;
  scroll_gesture_recognizer = nil;
  wheel_gesture_recognizer = nil;
  zoom_gesture_recognizer = nil;
  hover_gesture_recognizer = nil;
  edge_swipe_left = nil;
  edge_swipe_right = nil;

  if (two_finger_hold_active && virtual_pointer != nullptr) {
    virtual_pointer->setSource(GHOST_IOSPointerSource::Finger);
    virtual_pointer->button(GHOST_kButtonMaskRight, false);
    virtual_pointer->endRelative();
  }
  two_finger_hold_active = false;

  if (pencil_interaction != nil) {
    [pencil_interaction setDelegate:nil];
    [input_view removeInteraction:pencil_interaction];
    [pencil_interaction release];
    pencil_interaction = nil;
  }

  if (text_field != nil) {
    [text_field resignFirstResponder];
    text_field.delegate = nil;
    [text_field removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
    text_field.inputAccessoryView = nil;
    [text_field removeFromSuperview];
    [text_field release];
    text_field = nil;
  }
  [original_text release];
  original_text = nil;

  if (toolbar != nil) {
    toolbar.items = nil;
  }
  [toolbar_text_item release];
  [toolbar_text_stack release];
  [toolbar_tip_label release];
  [toolbar_value_label release];
  [toolbar_flexible_space_item release];
  [toolbar_done_editing_item release];
  [toolbar_cancel_editing_item release];
  [toolbar release];
  toolbar_text_item = nil;
  toolbar_text_stack = nil;
  toolbar_tip_label = nil;
  toolbar_value_label = nil;
  toolbar_flexible_space_item = nil;
  toolbar_done_editing_item = nil;
  toolbar_cancel_editing_item = nil;
  toolbar = nil;

  current_pencil_touch = nil;
  tablet_data = GHOST_TABLET_DATA_NONE;
  pencil_contact.reset();
  system = nullptr;
  window = nullptr;
  virtual_pointer = nullptr;
}

- (void)registerWindowControls
{
  if (window == nullptr || window->isMainWindow()) {
    return;
  }

  UIView *input_view = window->getView();
  close_window_button = [[UIButton buttonWithType:UIButtonTypeSystem] retain];
  close_window_button.translatesAutoresizingMaskIntoConstraints = NO;
  close_window_button.accessibilityLabel = @"Close window";
  close_window_button.accessibilityIdentifier = @"blender_child_window_close";
  close_window_button.tintColor = UIColor.whiteColor;
  close_window_button.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
  close_window_button.layer.cornerRadius = 22.0f;
  [close_window_button setImage:[UIImage systemImageNamed:@"xmark"]
                       forState:UIControlStateNormal];
  [close_window_button addTarget:self
                          action:@selector(handleCloseWindow)
                forControlEvents:UIControlEventTouchUpInside];
  [input_view addSubview:close_window_button];

  UILayoutGuide *safe_area = input_view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [close_window_button.widthAnchor constraintEqualToConstant:44.0f],
    [close_window_button.heightAnchor constraintEqualToConstant:44.0f],
    [close_window_button.topAnchor constraintEqualToAnchor:safe_area.topAnchor constant:8.0f],
    [close_window_button.trailingAnchor constraintEqualToAnchor:safe_area.trailingAnchor
                                                        constant:-8.0f],
  ]];

  [self updateFileAccessControls];
}

- (void)updateFileAccessControls
{
  GHOST_IOSFileAccess_destroyControls(file_access_controls);
  file_access_controls = nil;
  if (window == nullptr || close_window_button == nil) {
    return;
  }

  file_access_controls = GHOST_IOSFileAccess_createControls(window->getView(),
                                                            window->rootWindow.rootViewController,
                                                            close_window_button,
                                                            window->getTitle().c_str());
}

- (void)registerModifierBelt
{
  if (window == nullptr || modifier_belt != nil) {
    return;
  }
  modifier_belt = GHOST_IOSModifierBelt_create(window->getView(), self);
}

static GHOST_TModifierKey IOS_belt_modifier_key(const GHOST_IOSModifier modifier)
{
  switch (modifier) {
    case GHOST_IOSModifier::Shift:
      return GHOST_kModifierKeyLeftShift;
    case GHOST_IOSModifier::Control:
      return GHOST_kModifierKeyLeftControl;
    case GHOST_IOSModifier::Alt:
      return GHOST_kModifierKeyLeftAlt;
    case GHOST_IOSModifier::Command:
      return GHOST_kModifierKeyLeftOS;
  }
  return GHOST_kModifierKeyLeftShift;
}

/* Send the key presses and releases the belt needs, then show the result on its keys. */
- (void)applyModifierLatch
{
  if (modifier_latch == nullptr || system == nullptr || window == nullptr) {
    return;
  }
  /* App activation clears GHOST's modifier state without telling the latch. */
  GHOST_ModifierKeys keys;
  system->getModifierKeys(keys);
  for (int i = 0; i < GHOST_IOS_MODIFIER_COUNT; i++) {
    const GHOST_IOSModifier modifier = GHOST_IOSModifier(i);
    if (modifier_latch->sent(modifier) && !keys.get(IOS_belt_modifier_key(modifier))) {
      modifier_latch->forgetSent(modifier);
    }
  }

  GHOST_IOSModifierChange changes[GHOST_IOS_MODIFIER_COUNT];
  const int changes_num = modifier_latch->takeChanges(changes);
  for (int i = 0; i < changes_num; i++) {
    const GHOST_TKey key = GHOST_ModifierKeys::getModifierKeyCode(
        IOS_belt_modifier_key(changes[i].modifier));
    [self generateKeyEvent:key down:changes[i].down utf8:nullptr];
  }

  GHOST_IOSModifierMode modes[GHOST_IOS_MODIFIER_COUNT];
  for (int i = 0; i < GHOST_IOS_MODIFIER_COUNT; i++) {
    modes[i] = modifier_latch->mode(GHOST_IOSModifier(i));
  }
  GHOST_IOSModifierBelt_setModes(modifier_belt, modes);
}

- (void)modifierBeltKey:(GHOST_IOSModifier)modifier
                   down:(BOOL)down
              timestamp:(NSTimeInterval)timestamp
{
  if (modifier_latch == nullptr) {
    return;
  }
  if (down) {
    modifier_latch->keyDown(modifier, timestamp);
  }
  else {
    modifier_latch->keyUp(modifier, timestamp);
  }
  [self applyModifierLatch];
}

- (void)modifierBeltKeyCancelled:(GHOST_IOSModifier)modifier
{
  if (modifier_latch == nullptr) {
    return;
  }
  modifier_latch->keyCancelled(modifier);
  [self applyModifierLatch];
}

- (void)modifierBeltDidHide
{
  if (modifier_latch == nullptr) {
    return;
  }
  modifier_latch->clear();
  [self applyModifierLatch];
}

- (void)modifierBeltPointerButton:(bool)pressed
{
  if (modifier_latch == nullptr) {
    return;
  }
  if (pressed) {
    modifier_latch->pointerPressed();
  }
  else {
    modifier_latch->pointerReleased();
  }
  [self applyModifierLatch];
}

- (void)modifierBeltCursorMoved:(CGPoint)point visible:(bool)visible
{
  GHOST_IOSModifierBelt_setCursor(modifier_belt, point, visible);
}

- (void)handleCloseWindow
{
  if (system == nullptr || window == nullptr || window->isMainWindow()) {
    return;
  }
  system->handleWindowEvent(GHOST_kEventWindowClose, window);
}

- (BOOL)allowsPointerLock
{
  /* Child windows expose native close/file buttons, which need UIKit pointer delivery. */
  return window != nullptr && close_window_button == nil && !text_field.isFirstResponder;
}

- (void)dealloc
{
  [self invalidateInput];
  [super dealloc];
}

- (BOOL)canBecomeFirstResponder
{
  return YES;
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
  if (window == nullptr || window->isMainWindow()) {
    return @[];
  }

  UIKeyCommand *close_command = [UIKeyCommand keyCommandWithInput:@"w"
                                                    modifierFlags:UIKeyModifierCommand
                                                           action:@selector(handleCloseWindow)];
  close_command.discoverabilityTitle = @"Close Window";
  return @[ close_command ];
}

- (void)generateKeyEvent:(GHOST_TKey)key down:(bool)is_down utf8:(const char *)utf8
{
  GHOST_TModifierKey modifier;
  if (modifierForKey(key, modifier)) {
    system->updateModifierState(modifier, is_down);
  }

  system->pushEvent(std::make_unique<GHOST_EventKey>(system->getMilliSeconds(),
                                                      is_down ? GHOST_kEventKeyDown :
                                                                GHOST_kEventKeyUp,
                                                      window,
                                                      key,
                                                      false,
                                                      is_down ? utf8 : nullptr));
  system->notifyExternalEventProcessed();
}

- (void)generateUndoRedoShortcut:(bool)redo
{
  @synchronized(self) {
    [self generateKeyEvent:GHOST_kKeyLeftControl down:true utf8:nullptr];
    if (redo) {
      [self generateKeyEvent:GHOST_kKeyLeftShift down:true utf8:nullptr];
    }
    [self generateKeyEvent:GHOST_kKeyZ down:true utf8:"z"];
    [self generateKeyEvent:GHOST_kKeyZ down:false utf8:nullptr];
    if (redo) {
      [self generateKeyEvent:GHOST_kKeyLeftShift down:false utf8:nullptr];
    }
    [self generateKeyEvent:GHOST_kKeyLeftControl down:false utf8:nullptr];
  }
}

- (void)generateHardwareKeyEvents:(NSSet<UIPress *> *)presses
                              type:(GHOST_TEventType)event_type
{
  for (UIPress *press in presses) {
    UIKey *ui_key = press.key;
    if (ui_key == nil) {
      continue;
    }

    const GHOST_TKey key = convertKeyboardHIDUsage(ui_key.keyCode);
    const bool is_down = event_type == GHOST_kEventKeyDown;
    if (is_down && onscreen_keyboard_active) {
      text_field_stale = true;
    }
    char utf8[6] = {};
    if (is_down && ui_key.characters.length != 0) {
      NSData *encoded = [ui_key.characters dataUsingEncoding:NSUTF8StringEncoding];
      memcpy(utf8, encoded.bytes, std::min<NSUInteger>(encoded.length, sizeof(utf8) - 1));
    }
    [self generateKeyEvent:key down:is_down utf8:utf8];
  }
}

- (void)synchronizePointerModifiers:(UIKeyModifierFlags)flags
{
  GHOST_ModifierKeys keys;
  system->getModifierKeys(keys);
  struct ModifierPair {
    UIKeyModifierFlags flag;
    GHOST_TModifierKey left, right;
  };
  constexpr ModifierPair pairs[] = {
      {UIKeyModifierShift, GHOST_kModifierKeyLeftShift, GHOST_kModifierKeyRightShift},
      {UIKeyModifierControl, GHOST_kModifierKeyLeftControl, GHOST_kModifierKeyRightControl},
      {UIKeyModifierAlternate, GHOST_kModifierKeyLeftAlt, GHOST_kModifierKeyRightAlt},
      {UIKeyModifierCommand, GHOST_kModifierKeyLeftOS, GHOST_kModifierKeyRightOS},
  };
  for (const ModifierPair &pair : pairs) {
    if ((flags & pair.flag) == 0) {
      /* The snapshot only covers hardware keys. Keep keys held on the on-screen belt. */
      bool belt_holds = false;
      for (int i = 0; i < GHOST_IOS_MODIFIER_COUNT; i++) {
        const GHOST_IOSModifier modifier = GHOST_IOSModifier(i);
        belt_holds |= modifier_latch != nullptr && modifier_latch->sent(modifier) &&
                      IOS_belt_modifier_key(modifier) == pair.left;
      }
      if (belt_holds) {
        continue;
      }
      for (const GHOST_TModifierKey key : {pair.left, pair.right}) {
        if (keys.get(key)) {
          [self generateKeyEvent:GHOST_ModifierKeys::getModifierKeyCode(key) down:false utf8:nullptr];
        }
      }
    }
    else if (!keys.get(pair.left) && !keys.get(pair.right)) {
      [self generateKeyEvent:GHOST_ModifierKeys::getModifierKeyCode(pair.left) down:true utf8:nullptr];
    }
  }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  (void)event;
  [self generateHardwareKeyEvents:presses type:GHOST_kEventKeyDown];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  (void)event;
  [self generateHardwareKeyEvents:presses type:GHOST_kEventKeyUp];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  (void)event;
  [self generateHardwareKeyEvents:presses type:GHOST_kEventKeyUp];
}

- (void)registerGestureRecognizers
{
  /** Create Gesture recognisers. */
  /* Tap gesture recognizer. */
  tap_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap:)];
  tap_gesture_recognizer.delegate = self;
  tap_gesture_recognizer.cancelsTouchesInView = false;
  tap_gesture_recognizer.allowedTouchTypes = @[
    @(UITouchTypePencil), @(UITouchTypeDirect)
  ];
  [window->getView() addGestureRecognizer:tap_gesture_recognizer];

  /* One tap followed by a held second touch explicitly owns a left-button drag. */
  double_tap_drag_gesture_recognizer = [[GHOSTUILongPressGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleDoubleTapDrag:)];
  double_tap_drag_gesture_recognizer.delegate = self;
  double_tap_drag_gesture_recognizer.cancelsTouchesInView = false;
  double_tap_drag_gesture_recognizer.numberOfTapsRequired = 1;
  double_tap_drag_gesture_recognizer.numberOfTouchesRequired = 1;
  double_tap_drag_gesture_recognizer.minimumPressDuration = 0.12;
  double_tap_drag_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [window->getView() addGestureRecognizer:double_tap_drag_gesture_recognizer];

  /* A one-finger triple-tap emulates the desktop double-click used to rename
   * objects and edit other double-click-only controls. */
  triple_tap_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTripleTap:)];
  triple_tap_gesture_recognizer.delegate = self;
  triple_tap_gesture_recognizer.cancelsTouchesInView = false;
  triple_tap_gesture_recognizer.numberOfTapsRequired = 3;
  triple_tap_gesture_recognizer.numberOfTouchesRequired = 1;
  triple_tap_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [tap_gesture_recognizer requireGestureRecognizerToFail:triple_tap_gesture_recognizer];
  [tap_gesture_recognizer requireGestureRecognizerToFail:double_tap_drag_gesture_recognizer];
  [window->getView() addGestureRecognizer:triple_tap_gesture_recognizer];

  /* Two-finger tap gesture recognizer. */
  tap2f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap2F:)];
  tap2f_gesture_recognizer.delegate = self;
  tap2f_gesture_recognizer.cancelsTouchesInView = false;
  tap2f_gesture_recognizer.delaysTouchesBegan = YES;
  tap2f_gesture_recognizer.numberOfTapsRequired = 1;
  tap2f_gesture_recognizer.numberOfTouchesRequired = 2;
  tap2f_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];

  /* A stationary two-finger hold owns RMB. Movement can still start pan immediately. */
  two_finger_hold_gesture_recognizer = [[GHOSTUILongPressGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTwoFingerHold:)];
  two_finger_hold_gesture_recognizer.delegate = self;
  two_finger_hold_gesture_recognizer.cancelsTouchesInView = false;
  two_finger_hold_gesture_recognizer.numberOfTapsRequired = 0;
  two_finger_hold_gesture_recognizer.numberOfTouchesRequired = 2;
  two_finger_hold_gesture_recognizer.minimumPressDuration =
      GHOST_IOSInputTuning::two_finger_right_click_hold_seconds;
  two_finger_hold_gesture_recognizer.allowableMovement =
      GHOST_IOSInputTuning::two_finger_right_click_slop_points;
  two_finger_hold_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];

  [tap2f_gesture_recognizer requireGestureRecognizerToFail:two_finger_hold_gesture_recognizer];
  [window->getView() addGestureRecognizer:tap2f_gesture_recognizer];
  [window->getView() addGestureRecognizer:two_finger_hold_gesture_recognizer];

  /* Three-finger tap gesture recognizer. */
  tap3f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap3F:)];
  tap3f_gesture_recognizer.delegate = self;
  tap3f_gesture_recognizer.cancelsTouchesInView = false;
  tap3f_gesture_recognizer.delaysTouchesBegan = YES;
  tap3f_gesture_recognizer.numberOfTouchesRequired = 3;
  tap3f_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [window->getView() addGestureRecognizer:tap3f_gesture_recognizer];

  /* Four-finger tap gesture recognizer. */
  tap4f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap4F:)];
  tap4f_gesture_recognizer.delegate = self;
  tap4f_gesture_recognizer.cancelsTouchesInView = false;
  tap4f_gesture_recognizer.delaysTouchesBegan = YES;
  tap4f_gesture_recognizer.numberOfTouchesRequired = 4;
  tap4f_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [window->getView() addGestureRecognizer:tap4f_gesture_recognizer];

  /* A direct finger moves the virtual cursor relatively without pressing a button. */
  pan_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan:)];
  pan_gesture_recognizer.delegate = self;
  pan_gesture_recognizer.cancelsTouchesInView = false;
  /* Allow scrolling only with a single finger. */
  pan_gesture_recognizer.minimumNumberOfTouches = 1;
  pan_gesture_recognizer.maximumNumberOfTouches = 1;
  pan_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [window->getView() addGestureRecognizer:pan_gesture_recognizer];

  /* Pencil drags use absolute coordinates but share the same cursor. */
  pencil_drag_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePencilDrag:)];
  pencil_drag_gesture_recognizer.delegate = self;
  pencil_drag_gesture_recognizer.cancelsTouchesInView = false;
  pencil_drag_gesture_recognizer.minimumNumberOfTouches = 1;
  pencil_drag_gesture_recognizer.maximumNumberOfTouches = 1;
  pencil_drag_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypePencil)];
  [window->getView() addGestureRecognizer:pencil_drag_gesture_recognizer];

  /* Pan gesture recognizer - two fingers 3D UI. */
  pan2f_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan2f:)];
  pan2f_gesture_recognizer.delegate = self;
  pan2f_gesture_recognizer.cancelsTouchesInView = false;
  /* Two finger gestures only.  */
  pan2f_gesture_recognizer.minimumNumberOfTouches = 2;
  pan2f_gesture_recognizer.maximumNumberOfTouches = 2;
  pan2f_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [window->getView() addGestureRecognizer:pan2f_gesture_recognizer];

  /* Three-finger drag pans the 3D view. Keeping this separate from two-finger orbit avoids
   * changing Blender's established touch interaction and makes the gesture unambiguous. */
  pan3f_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan3f:)];
  pan3f_gesture_recognizer.delegate = self;
  pan3f_gesture_recognizer.cancelsTouchesInView = false;
  pan3f_gesture_recognizer.minimumNumberOfTouches = 3;
  pan3f_gesture_recognizer.maximumNumberOfTouches = 3;
  pan3f_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [window->getView() addGestureRecognizer:pan3f_gesture_recognizer];

  /* Keep discrete wheels separate from continuous trackpad gestures. Blender's
   * wheel keymap zooms the viewport and scrolls UI panels; trackpad pan orbits. */
  scroll_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePointerScroll:)];
  scroll_gesture_recognizer.delegate = self;
  scroll_gesture_recognizer.cancelsTouchesInView = false;
  scroll_gesture_recognizer.allowedTouchTypes = @[];
  scroll_gesture_recognizer.allowedScrollTypesMask = UIScrollTypeMaskContinuous;
  [window->getView() addGestureRecognizer:scroll_gesture_recognizer];

  wheel_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self action:@selector(handlePointerScroll:)];
  wheel_gesture_recognizer.delegate = self;
  wheel_gesture_recognizer.cancelsTouchesInView = false;
  wheel_gesture_recognizer.allowedTouchTypes = @[];
  wheel_gesture_recognizer.allowedScrollTypesMask = UIScrollTypeMaskDiscrete;
  [window->getView() addGestureRecognizer:wheel_gesture_recognizer];

  /* Pinch/Zoom gesture recognizer. */
  zoom_gesture_recognizer = [[GHOSTUIPinchGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleZoom:)];
  zoom_gesture_recognizer.delegate = self;
  zoom_gesture_recognizer.cancelsTouchesInView = false;
  zoom_gesture_recognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
  [window->getView() addGestureRecognizer:zoom_gesture_recognizer];

  /* Edge swipe. */
  edge_swipe_left = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_left.edges = UIRectEdgeLeft;
  edge_swipe_left.allowedTouchTypes = @[@(UITouchTypeDirect)];
  edge_swipe_left.delegate = self;
  [window->getView() addGestureRecognizer:edge_swipe_left];

  edge_swipe_right = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_right.edges = UIRectEdgeRight;
  edge_swipe_right.allowedTouchTypes = @[@(UITouchTypeDirect)];
  edge_swipe_right.delegate = self;
  [window->getView() addGestureRecognizer:edge_swipe_right];

  /* Apple Pencil hover recognizer. */
  hover_gesture_recognizer = [[GHOSTUIHoverGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleHover:)];
  hover_gesture_recognizer.delegate = self;
  [window->getView() addGestureRecognizer:hover_gesture_recognizer];
  current_pencil_touch = nil;

  /**  Apple Pencil double-tap. */
  pencil_interaction = [[UIPencilInteraction alloc] init];
  pencil_interaction.delegate = self;
  [window->getView() addInteraction:pencil_interaction];
}

/* Turn the user inputs into Blender events.
 * We batch up the events rather than send them directly in the gesture
 * recognisers to ensure we don't interleave events if we detect simultaneous
 * inputs. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info
{
  /* Lock access to ensure all input-events are received sequentially. */
  @synchronized(self) {
    for (int i = 0; i < event_info.num_events; i++) {
      UserInputEvent::EventTypes event_type = event_info.event_list[i];
      IOS_INPUT_LOG(@"%d-%@ %f,%f",
                    i,
                    event_info.getEventTypeDesc(event_type),
                    event_info.location.x,
                    event_info.location.y);

      switch (event_type) {
        case UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventScroll,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.translation.x,
                                                                  event_info.translation.y,
                                                                  true,
                                                                  2));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE_THREE_FINGERS:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventScroll,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.translation.x,
                                                                  event_info.translation.y,
                                                                  true,
                                                                  3,
                                                                  GHOST_kModifierKeyLeftShift));
          break;
        case UserInputEvent::EventTypes::POINTER_SCROLL:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventScroll,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.translation.x,
                                                                  event_info.translation.y,
                                                                  true));
          break;
        case UserInputEvent::EventTypes::PINCH_GESTURE:
          system->pushEvent(std::make_unique<GHOST_EventTrackpad>(system->getMilliSeconds(),
                                                                  window,
                                                                  GHOST_kTrackpadEventMagnify,
                                                                  event_info.location.x,
                                                                  event_info.location.y,
                                                                  event_info.distance,
                                                                  0,
                                                                  false,
                                                                  2));
          break;
        default:
          GHOST_ASSERT(FALSE, "GHOST_SystemIOS::generateUserInputEvents unsupported event type");
      }
    }
  }
}

/* Allow simultaneous gestures for two finger pans and zooms but nothing else. */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch
{
  (void)gestureRecognizer;
  if (close_window_button != nil &&
      (touch.view == close_window_button ||
       [touch.view isDescendantOfView:close_window_button]))
  {
    return NO;
  }
  if (GHOST_IOSFileAccess_containsView(file_access_controls, touch.view)) {
    return NO;
  }
  if (GHOST_IOSModifierBelt_containsView(modifier_belt, touch.view)) {
    return NO;
  }
  return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer
{
  if (gestureRecognizer == pan2f_gesture_recognizer &&
      otherGestureRecognizer == zoom_gesture_recognizer)
  {
    return YES;
  }
  return NO;
}

/* Pointer buttons must reach Blender before UIKit decides whether a movement is a pan.
 * With pointer lock, GameController owns mouse input. Without it, UIKit supplies absolute
 * pointing and a snapshot of all held buttons, including secondary and middle buttons. */
- (void)sendEvent:(UIEvent *)event
{
  if (window != nullptr && virtual_pointer != nullptr && !onscreen_keyboard_active &&
      !virtual_pointer->usesRelativeMouse() && event.type == UIEventTypeTouches &&
      self.rootViewController.presentedViewController == nil)
  {
    UIView *canvas = window->getView();
    for (UITouch *touch in event.allTouches) {
      if (touch.type != UITouchTypeIndirectPointer) {
        continue;
      }
      if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
        /* UIKit's mask includes the button being released, and the ended touch
         * may no longer have a view. End the held sequence before hit testing.
         * Pointer capture can cancel UIKit's touch while the button stays down. */
        if (touch.phase != UITouchPhaseCancelled || !virtual_pointer->wantsPointerLock()) {
          virtual_pointer->hardwareButtons(0);
        }
        continue;
      }
      if (!(touch.view == canvas || [touch.view isDescendantOfView:canvas]) ||
          (close_window_button != nil &&
           (touch.view == close_window_button ||
            [touch.view isDescendantOfView:close_window_button])) ||
          GHOST_IOSFileAccess_containsView(file_access_controls, touch.view) ||
          GHOST_IOSModifierBelt_containsView(modifier_belt, touch.view))
      {
        continue;
      }
      CGPoint point = [touch locationInView:canvas];
      point = window->scalePointToWindow(point);
      virtual_pointer->moveAbsolute(point.x, point.y, GHOST_IOSPointerSource::Hardware);
      /* UIKit owns normal pointing and buttons, including hit testing against native
       * controls. GameController takes over only while the pointer is captured. */
      unsigned int buttons = event.buttonMask;
      if (GCMouse.mice.count != 0) {
        /* During a multi-button sequence UIKit's mask is the union of the buttons
         * before and after a change. The physical profile identifies partial
         * releases, such as releasing left while right remains held. */
        buttons = 0;
        for (GCMouse *mouse in GCMouse.mice) {
          buttons |= mouse.mouseInput.leftButton.isPressed ? 1u : 0u;
          buttons |= mouse.mouseInput.rightButton.isPressed ? 2u : 0u;
          buttons |= mouse.mouseInput.middleButton.isPressed ? 4u : 0u;
        }
        if (touch.phase == UITouchPhaseBegan) {
          buttons |= event.buttonMask;
        }
      }
      virtual_pointer->hardwareButtons(buttons);
      break;
    }
  }
  [super sendEvent:event];
}

/* Override touch methods to capture the UITouch object. */
- (void)updateTabletDataFromTouch:(UITouch *)touch
{
  GHOST_ASSERT(touch.type == UITouchTypePencil, "Tablet data requires an Apple Pencil touch");
  current_pencil_touch = touch;
  tablet_data.Active = GHOST_kTabletModeStylus;

  CGFloat normalized_pressure = 0.0;
  if (touch.maximumPossibleForce > 0.0) {
    normalized_pressure = touch.force / touch.maximumPossibleForce;
  }
  tablet_data.Pressure = std::clamp(float(normalized_pressure), 0.0f, 1.0f);

  const CGFloat azimuth_angle = [touch azimuthAngleInView:window->getView()];
  const CGFloat altitude_angle = touch.altitudeAngle;
  const CGFloat tilt = cos(altitude_angle);

  tablet_data.Xtilt = std::clamp(float(sin(azimuth_angle) * tilt), -1.0f, 1.0f);
  tablet_data.Ytilt = std::clamp(float(-cos(azimuth_angle) * tilt), -1.0f, 1.0f);
  IOS_INPUT_LOG(
      @"TABLET: X:%f,Y:%f,P:%f", tablet_data.Xtilt, tablet_data.Ytilt, tablet_data.Pressure);
}

- (void)resetTabletData
{
  current_pencil_touch = nil;
  tablet_data = GHOST_TABLET_DATA_NONE;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesBegan:touches withEvent:event];

  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      [self updateTabletDataFromTouch:touch];
      const CGPoint point = [self scaledPencilPoint:touch];
      pencil_contact.touchBegan(point.x, point.y);
      break;
    }
  }
}

/* Get updated tablet data. */
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesMoved:touches withEvent:event];

  if (current_pencil_touch != nil) {
    for (UITouch *touch in touches) {
      if (touch == current_pencil_touch) {
        [self updateTabletDataFromTouch:touch];
        const CGPoint point = [self scaledPencilPoint:touch];
        pencil_contact.touchMoved(point.x, point.y);
        break;
      }
    }
  }
}

/* Reset tablet data. */
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesEnded:touches withEvent:event];
  if (current_pencil_touch != nil && [touches containsObject:current_pencil_touch]) {
    const CGPoint point = [self scaledPencilPoint:current_pencil_touch];
    pencil_contact.touchEnded(point.x, point.y);
    [self resetTabletData];
  }
}

/* Reset tablet data. */
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesCancelled:touches withEvent:event];
  if (current_pencil_touch != nil && [touches containsObject:current_pencil_touch]) {
    const CGPoint point = [self scaledPencilPoint:current_pencil_touch];
    pencil_contact.touchEnded(point.x, point.y);
    [self resetTabletData];
  }
}

- (CGPoint)scaledPencilPoint:(UITouch *)touch
{
  if (window == nullptr) {
    return CGPointZero;
  }
  CGPoint point = [touch preciseLocationInView:window->getView()];
  return window->scalePointToWindow(point);
}

- (CGPoint)getVirtualPointerPoint
{
  double pointer_x = 0.0;
  double pointer_y = 0.0;
  virtual_pointer->getClientPosition(pointer_x, pointer_y);
  return CGPointMake(pointer_x, pointer_y);
}

- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  const UITouchType touch_type = [sender getTouchType];
  GHOST_TabletData click_tablet = GHOST_TABLET_DATA_NONE;
  if (touch_type == UITouchTypePencil || touch_type == UITouchTypeIndirectPointer) {
    const CGPoint point = [sender getScaledTouchPoint:window];
    const GHOST_IOSPointerSource source = touch_type == UITouchTypePencil ?
                                              GHOST_IOSPointerSource::Pencil :
                                              GHOST_IOSPointerSource::Hardware;
    if (touch_type == UITouchTypePencil) {
      click_tablet = tablet_data;
    }
    virtual_pointer->moveAbsolute(point.x, point.y, source, click_tablet);
  }
  else {
    virtual_pointer->setSource(GHOST_IOSPointerSource::Finger);
  }
  virtual_pointer->click(GHOST_kButtonMaskLeft, click_tablet);
}

- (void)handleTripleTap:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  virtual_pointer->setSource(GHOST_IOSPointerSource::Finger);
  virtual_pointer->click(GHOST_kButtonMaskLeft);
  virtual_pointer->click(GHOST_kButtonMaskLeft);
  [sender resetFirstTapPoint];
}

- (void)handleDoubleTapDrag:(GHOSTUILongPressGestureRecognizer *)sender
{
  const CGPoint point = [sender getScaledTouchPoint:window];
  if (sender.state == UIGestureRecognizerStateBegan) {
    virtual_pointer->beginRelative(point.x, point.y);
    virtual_pointer->button(GHOST_kButtonMaskLeft, true);
    return;
  }

  if (sender.state == UIGestureRecognizerStateChanged) {
    virtual_pointer->moveRelativeTo(point.x, point.y);
    return;
  }

  if (sender.state == UIGestureRecognizerStateEnded ||
      sender.state == UIGestureRecognizerStateCancelled ||
      sender.state == UIGestureRecognizerStateFailed)
  {
    virtual_pointer->setSource(GHOST_IOSPointerSource::Finger);
    virtual_pointer->button(GHOST_kButtonMaskLeft, false);
    virtual_pointer->endRelative();
  }
}


- (void)handleTwoFingerHold:(GHOSTUILongPressGestureRecognizer *)sender
{
  const CGPoint point = [sender getScaledTouchPoint:window];
  if (sender.state == UIGestureRecognizerStateBegan) {
    two_finger_hold_active = true;
    virtual_pointer->beginRelative(point.x, point.y);
    virtual_pointer->button(GHOST_kButtonMaskRight, true);
    return;
  }

  if (sender.state == UIGestureRecognizerStateChanged && two_finger_hold_active) {
    virtual_pointer->moveRelativeTo(point.x, point.y);
    return;
  }

  if ((sender.state == UIGestureRecognizerStateEnded ||
       sender.state == UIGestureRecognizerStateCancelled ||
       sender.state == UIGestureRecognizerStateFailed) &&
      two_finger_hold_active)
  {
    virtual_pointer->setSource(GHOST_IOSPointerSource::Finger);
    virtual_pointer->button(GHOST_kButtonMaskRight, false);
    virtual_pointer->endRelative();
    two_finger_hold_active = false;
  }
}

- (void)handleTap2F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  [self generateUndoRedoShortcut:false];
}

- (void)handleTap3F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  [self generateUndoRedoShortcut:true];
}

- (void)handleTap4F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  [self generateKeyEvent:GHOST_kKeyF3 down:true utf8:nullptr];
  [self generateKeyEvent:GHOST_kKeyF3 down:false utf8:nullptr];
}

- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan) {
    const CGPoint initial_touch_point = [sender getScaledInitialTouchPoint:window];
    const CGPoint touch_point = [sender getScaledTouchPoint:window];
    virtual_pointer->beginRelativeAtTime(initial_touch_point.x,
                                         initial_touch_point.y,
                                         [sender getInitialTouchTimestamp]);
    virtual_pointer->moveRelativeToAtTime(
        touch_point.x, touch_point.y, [sender getTouchTimestamp]);
  }

  if (sender.state == UIGestureRecognizerStateChanged) {
    const CGPoint touch_point = [sender getScaledTouchPoint:window];
    virtual_pointer->moveRelativeToAtTime(
        touch_point.x, touch_point.y, [sender getTouchTimestamp]);
  }

  if (sender.state == UIGestureRecognizerStateEnded ||
      sender.state == UIGestureRecognizerStateCancelled ||
      sender.state == UIGestureRecognizerStateFailed)
  {
    virtual_pointer->endRelative();
  }
}

- (void)handlePencilDrag:(GHOSTUIPanGestureRecognizer *)sender
{
  const CGPoint point = [sender getScaledTouchPoint:window];
  if (sender.state == UIGestureRecognizerStateBegan) {
    pencil_contact.strokeBegan();
    pencil_contact.strokeMoved(point.x, point.y);
    virtual_pointer->moveAbsolute(
        point.x, point.y, GHOST_IOSPointerSource::Pencil, tablet_data);
    virtual_pointer->button(GHOST_kButtonMaskLeft, true, tablet_data);
  }
  else if (sender.state == UIGestureRecognizerStateChanged) {
    pencil_contact.strokeMoved(point.x, point.y);
    virtual_pointer->moveAbsolute(
        point.x, point.y, GHOST_IOSPointerSource::Pencil, tablet_data);
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    /* End where the tip left the screen. The recognizer has no touches left by now, and hover
     * stays blocked until the release below has been delivered (#61). */
    const double end_x = pencil_contact.hasPoint() ? pencil_contact.x() : point.x;
    const double end_y = pencil_contact.hasPoint() ? pencil_contact.y() : point.y;
    virtual_pointer->moveAbsolute(end_x, end_y, GHOST_IOSPointerSource::Pencil, tablet_data);
    virtual_pointer->button(GHOST_kButtonMaskLeft, false, tablet_data);
    pencil_contact.strokeEnded();
  }
}


- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender
{
  /* Translation can be non-zero on begin event */
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint translation = [sender getScaledTranslation:window];

    /* Calculate translation relative to previous cached value. */
    CGPoint relative_translation = [sender getRelativeTranslation:translation];

    /* Cache new translation. */
    [sender setCachedTranslation:translation];

    /* Generate pan event if translation is non zero. */
    if (!CGPointEqualToPoint(relative_translation, CGPointMake(0.0f, 0.0f))) {
      CGPoint touch_point = [self getVirtualPointerPoint];
      UserInputEvent event_info(&touch_point, &relative_translation, nullptr);
      event_info.add_event(UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS);
      [self generateUserInputEvents:event_info];
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    /* Set translation back to zero. */
    [sender setCachedTranslation:CGPointMake(0.0f, 0.0f)];
  }
}

- (void)handlePan3f:(GHOSTUIPanGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint translation = [sender getScaledTranslation:window];
    CGPoint relative_translation = [sender getRelativeTranslation:translation];
    [sender setCachedTranslation:translation];

    if (!CGPointEqualToPoint(relative_translation, CGPointMake(0.0f, 0.0f))) {
      CGPoint touch_point = [self getVirtualPointerPoint];
      UserInputEvent event_info(&touch_point, &relative_translation, nullptr);
      event_info.add_event(UserInputEvent::EventTypes::PAN_GESTURE_THREE_FINGERS);
      [self generateUserInputEvents:event_info];
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    [sender setCachedTranslation:CGPointMake(0.0f, 0.0f)];
  }
}

- (void)handlePointerScroll:(GHOSTUIPanGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint translation = [sender getScaledTranslation:window];
    CGPoint relative_translation = [sender getRelativeTranslation:translation];
    [sender setCachedTranslation:translation];

    if (!CGPointEqualToPoint(relative_translation, CGPointZero)) {
      /* UIKit can consume standalone modifier presses and remap Shift-wheel to
       * the horizontal axis. Reconcile the event's modifier snapshot before
       * queuing wheel events, then undo that axis remapping like Cocoa does. */
      [self synchronizePointerModifiers:sender.modifierFlags];
      if (sender == wheel_gesture_recognizer) {
        CGFloat x = relative_translation.x;
        CGFloat y = relative_translation.y;
        if ((sender.modifierFlags & UIKeyModifierShift) && y == 0.0) {
          /* UIKit's horizontal and vertical translations have opposite signs
           * for the same physical wheel report after Shift remapping. */
          y = -x;
          x = 0.0;
        }
        if (x != 0.0) {
          system->pushEvent(std::make_unique<GHOST_EventWheel>(
              system->getMilliSeconds(), window, GHOST_kEventWheelAxisHorizontal, x > 0 ? 1 : -1));
        }
        if (y != 0.0) {
          system->pushEvent(std::make_unique<GHOST_EventWheel>(
              system->getMilliSeconds(), window, GHOST_kEventWheelAxisVertical, y > 0 ? 1 : -1));
        }
        return;
      }
      CGPoint pointer_location = [self getVirtualPointerPoint];
      UserInputEvent event_info(&pointer_location, &relative_translation, nullptr);
      event_info.add_event(UserInputEvent::EventTypes::POINTER_SCROLL);
      [self generateUserInputEvents:event_info];
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    [sender setCachedTranslation:CGPointZero];
  }
}

- (void)handleEdgeSwipe:(UIScreenEdgePanGestureRecognizer *)gesture
{
  if (gesture.state != UIGestureRecognizerStateEnded) {
    return;
  }

  UIView *view = window->getView();
  CGPoint location = [gesture locationInView:view];

  GHOST_TTouchEventSubTypes ghostEventType;

  if (gesture.edges == UIRectEdgeLeft) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInLeft;
  }
  else if (gesture.edges == UIRectEdgeRight) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInRight;
  }
  else {
    /* For now only handle left/right. */
    return;
  }

  system->pushEvent(std::make_unique<GHOST_EventTouch>(
      system->getMilliSeconds(), window, ghostEventType, location.x, location.y));
}

- (void)handleHover:(GHOSTUIHoverGestureRecognizer *)sender
{
  if ([sender getTouchType] != UITouchTypePencil && virtual_pointer->usesRelativeMouse()) {
    return;
  }
  /* Hover-capable iPads can report the last hover point, where the stroke started, while the tip
   * is down or lifting. Moving there before the release drags the stroke back (#61). */
  if (!pencil_contact.acceptsHover()) {
    return;
  }

  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    GHOST_IOSPointerSource source = GHOST_IOSPointerSource::Hardware;
    if ([sender getTouchType] == UITouchTypePencil) {
      /* Pencil hover needs absolute tablet motion; pointer hover must remain a mouse. */
      tablet_data.Active = GHOST_kTabletModeStylus;
      source = GHOST_IOSPointerSource::Pencil;
    }
    else {
      tablet_data = GHOST_TABLET_DATA_NONE;
    }
    const CGPoint hover_point = [sender getScaledTouchPoint:window];
    virtual_pointer->moveAbsolute(hover_point.x, hover_point.y, source, tablet_data);
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    tablet_data = GHOST_TABLET_DATA_NONE;
  }
}

- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender
{
  /* Ignore any calls where don't have two touches to work with. */
  if ([sender numberOfTouches] < 2) {
    return;
  }

  /* Pinch/Zoom gestures */
  if (sender.state == UIGestureRecognizerStateBegan) {
    /* Set an initial distance value. */
    CGFloat point_distance = [sender getScaledDistance:window];
    [sender setCachedDistance:point_distance];
  }
  else if (sender.state == UIGestureRecognizerStateChanged) {

    /* Calculate change in distance since last event */
    CGFloat point_distance = [sender getScaledDistance:window];
    CGFloat relative_dist = point_distance - [sender getCachedDistance];

    /* Updated cached distance. */
    [sender setCachedDistance:point_distance];

    /* Send pinch/zoom event. */
    if (fabs(relative_dist) > 0.0) {
      CGPoint midPoint = [self getVirtualPointerPoint];

      UserInputEvent event_info(&midPoint, nullptr, &relative_dist);
      event_info.add_event(UserInputEvent::EventTypes::PINCH_GESTURE);
      [self generateUserInputEvents:event_info];
    }
  }
  /* Nothing to do here. */
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
  }
}

- (void)pencilInteractionDidTap:(UIPencilInteraction *)interaction
{
  (void)interaction;
  virtual_pointer->setSource(GHOST_IOSPointerSource::Pencil);
  virtual_pointer->click(GHOST_kButtonMaskRight, tablet_data);
}

- (void)beginFrame
{
}

- (void)endFrame
{
}

- (void)initToolbar
{
  UIView *ui_view = window->getView();
  CGSize frame_size = ui_view.bounds.size;
  toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, frame_size.width, 44)];
  toolbar.barStyle = UIBarStyleDefault;
  toolbar.translucent = true;
  toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  toolbar.accessibilityIdentifier = @"blender_text_entry_toolbar";
  [toolbar sizeToFit];

  toolbar_tip_label = [[UILabel alloc] init];
  toolbar_tip_label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
  toolbar_tip_label.textColor = UIColor.secondaryLabelColor;
  toolbar_tip_label.textAlignment = NSTextAlignmentCenter;
  toolbar_tip_label.numberOfLines = 1;
  toolbar_tip_label.lineBreakMode = NSLineBreakByTruncatingTail;
  toolbar_tip_label.accessibilityIdentifier = @"blender_text_entry_description";

  toolbar_value_label = [[UILabel alloc] init];
  toolbar_value_label.font = [UIFont monospacedDigitSystemFontOfSize:18.0f
                                                              weight:UIFontWeightSemibold];
  toolbar_value_label.textColor = UIColor.labelColor;
  toolbar_value_label.textAlignment = NSTextAlignmentCenter;
  toolbar_value_label.numberOfLines = 1;
  toolbar_value_label.adjustsFontSizeToFitWidth = YES;
  toolbar_value_label.minimumScaleFactor = 0.65f;
  toolbar_value_label.accessibilityIdentifier = @"blender_text_entry_value";

  toolbar_text_stack = [[UIStackView alloc]
      initWithArrangedSubviews:@[ toolbar_tip_label, toolbar_value_label ]];
  toolbar_text_stack.axis = UILayoutConstraintAxisVertical;
  toolbar_text_stack.alignment = UIStackViewAlignmentFill;
  toolbar_text_stack.distribution = UIStackViewDistributionFill;
  toolbar_text_stack.spacing = -2.0f;
  toolbar_text_stack.translatesAutoresizingMaskIntoConstraints = NO;
  const CGFloat available_width = std::max<CGFloat>(120.0f, frame_size.width - 190.0f);
  [NSLayoutConstraint activateConstraints:@[
    [toolbar_text_stack.widthAnchor
        constraintEqualToConstant:std::min<CGFloat>(available_width, 520.0f)],
    [toolbar_text_stack.heightAnchor constraintEqualToConstant:40.0f],
  ]];
  toolbar_text_item = [[UIBarButtonItem alloc] initWithCustomView:toolbar_text_stack];

  toolbar_flexible_space_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                           target:nil
                           action:nil];

  toolbar_done_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(handleDoneButton)];

  toolbar_cancel_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                           target:self
                           action:@selector(handleCancelButton)];

  toolbar_cancel_editing_item.accessibilityIdentifier = @"blender_text_entry_cancel";
  toolbar_done_editing_item.accessibilityIdentifier = @"blender_text_entry_done";

  toolbar.items = @[
    toolbar_cancel_editing_item,
    toolbar_flexible_space_item,
    toolbar_text_item,
    toolbar_done_editing_item
  ];
}

- (void)generateKeyboardReturnEvent
{
  [self generateKeyboardCompletionEvent:GHOST_kKeyEnter];
}

- (void)generateKeyboardCompletionEvent:(GHOST_TKey)key
{
  /*
   Only push the event back if the keyboard is active otherwise we may generate new
   spurious events.
   */
  if (onscreen_keyboard_active) {
    /*
     This event should cause ui_textedit_end() to be called which will
     hide the keyboard.
     */
    const uint64_t event_time = system->getMilliSeconds();
    system->pushEvent(std::make_unique<GHOST_EventKey>(
        event_time, GHOST_kEventKeyDown, window, key, false, nullptr));
    system->pushEvent(std::make_unique<GHOST_EventKey>(
        event_time, GHOST_kEventKeyUp, window, key, false, nullptr));
    system->notifyExternalEventProcessed();
  }
  else {
    IOS_INPUT_LOG(@"Ignoring handleKeyboardReturn %@", text_field.text);
  }
}

- (void)handleKeyboardReturn:(UITextField *)sender
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"handleKeyboardReturn %@", sender.text);
    [self generateKeyboardReturnEvent];
  }
}

- (BOOL)textField:(UITextField *)sender
    shouldChangeCharactersInRange:(NSRange)range
                replacementString:(NSString *)replacement_string
{
  @synchronized(self) {
    if (!onscreen_keyboard_active) {
      return YES;
    }

    /* UIKit owns the hidden responder while Blender owns the visible edit string. Mirror each
     * native edit as ordinary key events so live controls, especially search fields, update before
     * the keyboard is dismissed. One backspace replaces either the current selection or the
     * character immediately before the cursor, matching UITextField's edit range. */
    if (range.length > 0) {
      [self generateKeyEvent:GHOST_kKeyBackSpace down:true utf8:nullptr];
      [self generateKeyEvent:GHOST_kKeyBackSpace down:false utf8:nullptr];
    }

    NSData *encoded = [replacement_string dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = static_cast<const unsigned char *>(encoded.bytes);
    for (NSUInteger offset = 0; offset < encoded.length;) {
      const unsigned char lead = bytes[offset];
      NSUInteger scalar_length = 1;
      if ((lead & 0xe0) == 0xc0) {
        scalar_length = 2;
      }
      else if ((lead & 0xf0) == 0xe0) {
        scalar_length = 3;
      }
      else if ((lead & 0xf8) == 0xf0) {
        scalar_length = 4;
      }
      scalar_length = std::min(scalar_length, encoded.length - offset);

      char utf8[6] = {};
      memcpy(utf8, bytes + offset, scalar_length);
      [self generateKeyEvent:GHOST_kKeyUnknown down:true utf8:utf8];
      [self generateKeyEvent:GHOST_kKeyUnknown down:false utf8:nullptr];
      offset += scalar_length;
    }
  }
  return YES;
}

- (void)handleKeyboardEditChange:(UITextField *)sender
{
  @synchronized(self) {

    IOS_INPUT_LOG(@"Keyboard Edit change detected %@", text_field.text);
    const char *utf8 = [sender.text UTF8String];
    text_field_string = utf8 != nullptr ? utf8 : "";
    toolbar_value_label.text = sender.text;
    toolbar_value_label.accessibilityValue = sender.text;
  }
}

- (void)handleKeyboardEditBegin:(UITextField *)text_field
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard Edit begin detected %@", text_field.text);
  }
}

- (void)handleKeyboardEditEnd:(UITextField *)text_field
{
  @synchronized(self) {
    /*
     This can get called when the keyboard is minimised
     so send a return keypress to emulate effective end
     of editing. Otherwise Blender's focus will remain
     on the text field.
     */
    IOS_INPUT_LOG(@"Keyboard Edit end detected %@", text_field.text);
    [self generateKeyboardReturnEvent];
  }
}

- (void)handleDoneButton
{
  IOS_INPUT_LOG(@"Keyboard Done button press detected %@", text_field.text);
  [self generateKeyboardReturnEvent];
}

- (void)handleCancelButton
{
  IOS_INPUT_LOG(@"Keyboard Cancel button press detected %@", text_field.text);
  /* Let Blender cancel its own edit state instead of committing a replacement value. */
  text_field.text = original_text;
  [self generateKeyboardCompletionEvent:GHOST_kKeyEsc];
}

/*
 * Add a text field so we can handle input from a popup keyboard and
 * attach it to our root window.
 */
- (void)initUITextField
{
  /* Initialise it if we have not already done so. */
  if (!text_field) {
    text_field = [[UITextField alloc] init];

    text_field.contentScaleFactor = window->getWindowScaleFactor();
    text_field.returnKeyType = UIReturnKeyDone;
    text_field.enablesReturnKeyAutomatically = NO;
    text_field.accessibilityLabel = @"Blender text entry";
    text_field.accessibilityIdentifier = @"blender_text_entry";
    text_field.borderStyle = UITextBorderStyleNone;
    text_field.clearButtonMode = UITextFieldViewModeNever;
    text_field.frame = CGRectMake(0.0f, 0.0f, 1.0f, 1.0f);
    text_field.backgroundColor = UIColor.clearColor;
    text_field.textColor = UIColor.clearColor;
    text_field.tintColor = UIColor.clearColor;
    text_field.hidden = YES;
    text_field.delegate = self;

    if (toolbar_enabled) {
      [self initToolbar];
      text_field.inputAccessoryView = toolbar;
    }

    [window->rootWindow addSubview:text_field];

    /* Add a handler for when 'return' is pressed on keyboard. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardReturn:)
         forControlEvents:UIControlEventEditingDidEndOnExit];

    /* Add a handler for when the text field changes. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditChange:)
         forControlEvents:UIControlEventEditingChanged];

    /* Add a handler for when user edits a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditBegin:)
         forControlEvents:UIControlEventEditingDidBegin];

    /* Add a handler for when user finishes editing a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditEnd:)
         forControlEvents:UIControlEventEditingDidEnd];
  }
}

- (UITextField *)getUITextField
{
  return text_field;
}

- (void)setupKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  /* Initialise it if we have not already done so */
  if (!text_field) {
    [self initUITextField];
  }

  /* The native field only owns the responder and keyboard. Keeping its one-point
   * frame at the window edge prevents it from covering a Blender control or being
   * pushed under the software keyboard; the accessory bar presents the live value. */
  text_field.frame = CGRectMake(0.0f, 0.0f, 1.0f, 1.0f);
  text_field.hidden = NO;

  /* Initialise text with existing string. */
  text_field.text = keyboard_properties.text_string ?
                        [NSString stringWithUTF8String:keyboard_properties.text_string] :
                        @"";
  /* Keep the cancel value alive for the full edit session. */
  [original_text release];
  original_text = [text_field.text copy];
  text_field_stale = false;
  toolbar_value_label.text = text_field.text;
  toolbar_value_label.accessibilityValue = text_field.text;

  /* Numeric Blender fields also accept expressions, units and drivers. Keep the full keyboard
   * available for every field until a Blender-specific expression keyboard exists. */
  text_field.keyboardType = UIKeyboardTypeDefault;
  text_field.textAlignment = NSTextAlignmentLeft;
  /* Set light/dark mode or adopt system default. */
  text_field.keyboardAppearance = UIKeyboardAppearanceDefault;

  /* Blender owns validation and completion. UIKit must not rewrite expressions. */
  text_field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  text_field.autocorrectionType = UITextAutocorrectionTypeNo;
  text_field.spellCheckingType = UITextSpellCheckingTypeNo;
  text_field.smartDashesType = UITextSmartDashesTypeNo;
  text_field.smartQuotesType = UITextSmartQuotesTypeNo;

  /* Setup the tool bar if it's enabled. */
  if (toolbar_enabled) {
    NSString *tip = keyboard_properties.tip_text ?
                        [NSString stringWithCString:keyboard_properties.tip_text
                                           encoding:NSUTF8StringEncoding] :
                        @"";
    toolbar_tip_label.text = tip.length != 0 ? tip : @"Value";
    toolbar_tip_label.accessibilityLabel = tip;
  }
}

- (void)applyKeyboardSelection:(const GHOST_KeyboardProperties &)keyboard_properties
{
  /* UIKit resets selection while a field becomes first responder, so apply this afterwards. */
  switch (keyboard_properties.inital_text_state) {
    case GHOST_KeyboardProperties::select_all_text: {
      [text_field selectAll:nil];
      break;
    }
    case GHOST_KeyboardProperties::select_text_range: {
      UITextPosition *startPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[0]];
      UITextPosition *endPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[1]];
      text_field.selectedTextRange = [text_field textRangeFromPosition:startPosition
                                                            toPosition:endPosition];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_start: {
      UITextPosition *beginning = text_field.beginningOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:beginning
                                                            toPosition:beginning];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_end: {
      UITextPosition *end = text_field.endOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:end toPosition:end];
      break;
    }
    default: {
      GHOST_ASSERT(FALSE, "GHOST_SystemIOS::setupTextField unsupported text select option");
    }
  }
}

- (const GHOST_TabletData)getTabletData
{
  return tablet_data;
}

- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard popup request received %@", text_field.text);
    [self setupKeyboard:keyboard_properties];

    if (!onscreen_keyboard_active) {
      text_field.userInteractionEnabled = YES;
      if (![text_field becomeFirstResponder]) {
        text_field.userInteractionEnabled = NO;
        text_field.hidden = YES;
        return GHOST_kFailure;
      }
      onscreen_keyboard_active = true;
      [self.rootViewController setNeedsUpdateOfPrefersPointerLocked];
      [self applyKeyboardSelection:keyboard_properties];
    }
  }
  return GHOST_kSuccess;
}

- (GHOST_TSuccess)hideOnscreenKeyboard
{
  /* Lock access around keyboard handling events. */
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard hide request received %@", text_field.text);

    if (onscreen_keyboard_active) {
      /*
       This must come first so that any of the keyboard event handlers that get
       triggered in response to shutting down the keyboard don't do anything
       (like generating events back to Blender)
       */
      onscreen_keyboard_active = false;

      /* Shut down the keyboard. */
      [text_field resignFirstResponder];
      [self becomeFirstResponder];
      [self.rootViewController setNeedsUpdateOfPrefersPointerLocked];
      /*
       IOS_FIXME - Note: This may cause the console to display the warning message:
       "-[UIApplication _touchesEvent] will no longer work as expected. Please stop using it."
       But since this is being generated by Apple OS code there's nothing obvious to fix it right
       now.
       */

      IOS_INPUT_LOG(@"Resigned keyboard responder");
      /*
       This is required to disable any subsequent interactions with the text field that could
       potentially bypass Blender's input handling (since the UITextField is now live
       on the view)
       */
      text_field.userInteractionEnabled = NO;

      /* NSString owns its UTF8String buffer, so copy it before clearing the field. */
      const char *utf8 = [[text_field text] UTF8String];
      text_field_string = utf8 != nullptr ? utf8 : "";

      /* Delete the text field copy of the string */
      text_field.text = nil;
      toolbar_tip_label.text = @"";
      toolbar_value_label.text = @"";
      text_field.hidden = YES;
    }
  }
  IOS_INPUT_LOG(@"Text field value was %s", text_field_string.c_str());
  return GHOST_kSuccess;
}

- (const char *)getLastKeyboardString
{
  /* Lock access around keyboard handling events */
  @synchronized(self) {
    /* Blender already has the hardware edits; the native copy would undo them (#69). */
    if (text_field_stale) {
      return nullptr;
    }

    /* UIKit normalizes a cleared text property to an empty string. Once the keyboard is hidden,
     * keep the value captured by hideOnscreenKeyboard instead of replacing it with that empty
     * placeholder. While active, this still supports reading live edits, including an empty one. */
    if (onscreen_keyboard_active && text_field.text != nil) {
      const char *utf8 = [text_field.text UTF8String];
      text_field_string = utf8 != nullptr ? utf8 : "";
    }
  }
  return text_field_string.c_str();
}

@end

@interface GHOST_IOSViewController : UIViewController

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
                                windowScene:(nonnull UIWindowScene *)windowScene;

@end

@implementation GHOST_IOSViewController
{
  MTKView *_view;
  GHOST_IOSMetalRenderer *_renderer;
  UIScreen *_screen;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
                                windowScene:(nonnull UIWindowScene *)windowScene
{
  self = [super init];
  if (self) {
    _view = mtkView;
    _screen = windowScene.screen;
    _view.multipleTouchEnabled = YES;
    self.view = (UIView *)mtkView;
  }

  return self;
}

- (BOOL)prefersPointerLocked
{
  GHOSTUIWindow *input_window = (GHOSTUIWindow *)self.view.window;
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  return system != nullptr && system->virtualPointer() != nullptr &&
         system->virtualPointer()->wantsPointerLock() &&
         [input_window allowsPointerLock];
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  _view = (MTKView *)self.view;
  _view.enableSetNeedsDisplay = NO;
  _view.device = MTLCreateSystemDefaultDevice();
  _view.clearColor = MTLClearColorMake(0, 0, 0, 1.0);
  _view.paused = NO;
  _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  _view.autoResizeDrawable = YES;
  _view.contentMode = UIViewContentModeScaleToFill;
  /* MetalKit derives its drawable in native pixels. Do not force UIScreen.scale here:
   * Display Zoom can make the logical and native backing scales differ. */
  /* Set the refresh rate to the screen's maximum. There may be some value in capping
   * this value to preserve battery life (60fps seems to work well). */
  _view.preferredFramesPerSecond = _screen.maximumFramesPerSecond;
  _renderer = [[GHOST_IOSMetalRenderer alloc] initWithMetalKitView:_view];
  if (!_renderer) {
    NSLog(@"Renderer initialization failed");
    return;
  }

  [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];

  _view.delegate = _renderer;
}

- (void)handleGesture:(UIGestureRecognizer *)gestureRecognizer
{
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
  /* Make the Home Indicator (the bottom-center white navigation bar) auto-hide when possible. */
  return YES;
}

@end

GHOST_WindowIOS::GHOST_WindowIOS(GHOST_SystemIOS *system_ios,
                                 const char *title,
                                 int32_t left,
                                 int32_t bottom,
                                 uint32_t width,
                                 uint32_t height,
                                 GHOST_TWindowState state,
                                 GHOST_TDrawingContextType type,
                                 const GHOST_ContextParams &context_params,
                                 bool is_main_window,
                                 bool is_dialog,
                                 GHOST_WindowIOS *parent_window)
    : GHOST_Window(width, height, state, context_params, false),
      metal_view_(nil),
      is_main_window_(is_main_window),
      is_dialog_(is_dialog)
{
  /* Fill the device screen. Page-sheet + alert-level windows otherwise float as a
   * card over SpringBoard on iPad (native idiom, but not a full-screen iPad app). */
  full_screen_ = true;
  system_ios_ = system_ios;
  /* Parent window will be the window that focus is returned to upon close. */
  parent_window_ = parent_window;
  window_title_ = nullptr;

  /* Create MTKView. */
  metal_view_ = [[MTKView alloc] initWithFrame:CGRectMake(left, bottom, width, height)];
  GHOST_ASSERT(metal_view_, "metalview not valid");

  UIWindowScene *window_scene = GHOST_IOS_activeWindowScene();
  GHOST_ASSERT(window_scene != nil, "An active UIWindowScene is required");

  GHOSTUIWindow *ghost_rootWindow = nullptr;
  ghost_rootWindow = [[GHOSTUIWindow alloc] initWithWindowScene:window_scene];
  if (!full_screen_) {
    ghost_rootWindow.frame = CGRectMake(left, bottom, width, height);
    [ghost_rootWindow setClipsToBounds:YES];
  }

  rootWindow = (UIWindow *)ghost_rootWindow;

  [ghost_rootWindow setSystemAndWindowIOS:system_ios_ windowIOS:this];
  rootWindow.windowLevel = UIWindowLevelNormal;

  GHOST_ASSERT(rootWindow, "UIWindow not valid");
  uiview_controller_ = [[GHOST_IOSViewController alloc] initWithMetalKitView:metal_view_
                                                                 windowScene:window_scene];
  [uiview_controller_ viewDidLoad];
  GHOST_ASSERT(uiview_controller_, "UIViewController not valid");

  /* Set presentation style depending on whether main window, dialog or temporary window. */
  if (full_screen_) {
    /* Initial window has no parent and is always fullscreen. */
    uiview_controller_.modalPresentationStyle = UIModalPresentationFullScreen;
  }
  else {
    /* Initial window has no parent and is always fullscreen. */
    uiview_controller_.modalPresentationStyle = UIModalPresentationPageSheet;
  }
  rootWindow.rootViewController = uiview_controller_;
  metal_view_.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
  metal_view_.frame = rootWindow.bounds;

  /* Create UIView */
  GHOST_ASSERT(width > 0 && height > 0, "invalid wh");
  uiview_ = uiview_controller_.view;
  GHOST_ASSERT(uiview_, "uiview not valid");

  /* Initialize Metal device. */
  metal_view_.device = MTLCreateSystemDefaultDevice();

  /* Enable HDR/EDR Support. */
  CAMetalLayer *metalLayer = (CAMetalLayer *)metal_view_.layer;
  metalLayer.wantsExtendedDynamicRangeContent = YES;
  metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
  CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
  metalLayer.colorspace = colorspace;
  CGColorSpaceRelease(colorspace);

  setDrawingContextType(type);
  updateDrawingContext();
  activateDrawingContext();

  setTitle(title);

  /* Gesture recognizers. */
  [ghost_rootWindow registerGestureRecognizers];
  [ghost_rootWindow registerWindowControls];
  [ghost_rootWindow registerModifierBelt];

  /* Deactive the parent (if it exists) and activate this one. */
  if (parent_window_) {
    parent_window_->requestToDeactivateWindow();
  }

  /* Make it the key window if there is no other window.
   * (Otherwise there will never be a call to drawInMTKView) */
  if (!system_ios_->current_active_window_) {
    request_to_make_active_ = true;
    makeKeyWindow();
  }
  /* Activate this window at the end of the next draw loop. */
  else {
    requestToActivateWindow();
  }
}

GHOST_WindowIOS::~GHOST_WindowIOS()
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  system_ios_->virtualPointer()->detachWindow(this);
  releaseNativeHandles();

  /* Restore application control and display to parent window. */
  if (parent_window_) {
    parent_window_->requestToActivateWindow();
    parent_window_ = nil;
  }
  /* We have no choice but to resign, however this seems like it might cause issues. */
  if (system_ios_->current_active_window_ == this) {
    IOS_WINDOW_LOG(@"~GHOST_WindowIOS(): Warning, deactivating the active window %p?", this);
    requestToDeactivateWindow();
    resignKeyWindow();
  }

  if (rootWindow) {
    /* UIWindowScene can retain a released window in its window stack. Hide it explicitly so a
     * closed full-screen window can never cover the parent after its controls are detached. */
    rootWindow.hidden = YES;
    [(GHOSTUIWindow *)rootWindow invalidateInput];
  }

  if (metal_view_) {
    metal_view_.delegate = nil;
    [metal_view_ release];
    metal_view_ = nil;
  }
  if (uiview_) {
    uiview_ = nil;
  }

  /* Release window. */
  if (rootWindow) {
    [rootWindow release];
    rootWindow = nil;
  }
  if (uiview_controller_) {
    [uiview_controller_ release];
    uiview_controller_ = nil;
  }

  if (window_title_) {
    free(window_title_);
    window_title_ = nullptr;
  }

  [pool drain];
}

#pragma mark accessors

bool GHOST_WindowIOS::getValid() const
{
  MTKView *view = metal_view_;
  return GHOST_Window::getValid() && uiview_ != NULL && view != NULL;
}

void *GHOST_WindowIOS::getOSWindow() const
{
  return (void *)uiview_;
}

GHOST_TSuccess GHOST_WindowIOS::swapBufferRelease()
{
  noteActivity();
  deferred_swap_buffers_ = true;
  return GHOST_kSuccess;
}

void GHOST_WindowIOS::flushDeferredSwapBuffers()
{
  if (!deferred_swap_buffers_) {
    return;
  }

  /* Consume the request before presenting so a later request cannot be erased by this frame. */
  deferred_swap_buffers_ = false;

  /* These two messages should be made asserts when we've fixed all the issues. */
  if (!getValid()) {
    IOS_WINDOW_LOG(@"Ignoring swap (invalid) con(%p) (win=%p)", getContext(), this);
    return;
  }

  if (!is_active_window_) {
    IOS_WINDOW_LOG(@"Ignoring swap (not active window) con(%p) (win=%p)", getContext(), this);
    return;
  }

  IOS_WINDOW_LOG(@"Swapping (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 uiview_,
                 metal_view_,
                 getContext(),
                 this);

  GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
  context->swapBufferRelease();
}

void GHOST_WindowIOS::beginFrame()
{
  GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
  context->beginFrame();
  GHOSTUIWindow *ui_window = (GHOSTUIWindow *)rootWindow;
  [ui_window beginFrame];
}

void GHOST_WindowIOS::endFrame()
{
  GHOSTUIWindow *ui_window = (GHOSTUIWindow *)rootWindow;
  [ui_window endFrame];
  /* Poll timers at 30 Hz while nothing is changing. Input and every requested
   * redraw restore the display's full rate, including animation and Cycles. */
  if (system_ios_->getMilliSeconds() - last_activity_ms_ >= 750) {
    const NSInteger idle_fps = std::min<NSInteger>(30, rootWindow.screen.maximumFramesPerSecond);
    if (metal_view_.preferredFramesPerSecond != idle_fps) {
      metal_view_.preferredFramesPerSecond = idle_fps;
    }
  }
}

void GHOST_WindowIOS::noteActivity()
{
  last_activity_ms_ = system_ios_->getMilliSeconds();
  const NSInteger active_fps = rootWindow.screen.maximumFramesPerSecond;
  if (metal_view_.preferredFramesPerSecond != active_fps) {
    metal_view_.preferredFramesPerSecond = active_fps;
  }
}

void GHOST_WindowIOS::modifierBeltPointerButton(const bool pressed)
{
  [(GHOSTUIWindow *)rootWindow modifierBeltPointerButton:pressed];
}

void GHOST_WindowIOS::modifierBeltCursorMoved(const double x, const double y, const bool visible)
{
  [(GHOSTUIWindow *)rootWindow modifierBeltCursorMoved:CGPointMake(x, y) visible:visible];
}

void GHOST_WindowIOS::setTitle(const char *title)
{
  if (window_title_) {
    free(window_title_);
    window_title_ = nullptr;
  }
  window_title_ = (char *)malloc(strlen(title) + 1);
  if (!window_title_) {
    GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setTitle(): Failed to alloc mem for window title");
  }
  strcpy(window_title_, title);
  NSString *window_title = [NSString stringWithCString:title encoding:NSUTF8StringEncoding];
  uiview_controller_.title = window_title;
}

std::string GHOST_WindowIOS::getTitle() const
{
  return window_title_;
}

void GHOST_WindowIOS::getWindowBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  CGRect window_rect = rootWindow.frame;
  const CGFloat scale = getWindowScaleFactor();

  bounds.b_ = CGRectGetMaxY(window_rect) * scale;
  bounds.l_ = CGRectGetMinX(window_rect) * scale;
  bounds.r_ = CGRectGetMaxX(window_rect) * scale;
  bounds.t_ = CGRectGetMinY(window_rect) * scale;
}

void GHOST_WindowIOS::getClientBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  const CGSize drawable_size = metal_view_.drawableSize;

  bounds.b_ = std::lround(drawable_size.height);
  bounds.l_ = 0;
  bounds.r_ = std::lround(drawable_size.width);
  bounds.t_ = 0;
}

GHOST_TSuccess GHOST_WindowIOS::setClientWidth(uint32_t /*width*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientHeight(uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientSize(uint32_t /*width*/, uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TWindowState GHOST_WindowIOS::getState() const
{
  /* TODO: Implement. */
  return GHOST_kWindowStateNormal;
}

void GHOST_WindowIOS::screenToClient(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::screenToClient(): window invalid");
  screenToClientIntern(inX, inY, outX, outY);
}

void GHOST_WindowIOS::clientToScreen(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::clientToScreen(): window invalid");
  clientToScreenIntern(inX, inY, outX, outY);
}

void GHOST_WindowIOS::screenToClientIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  UIWindowScene *window_scene = rootWindow.windowScene;
  GHOST_ASSERT(window_scene != nil, "A UIWindowScene is required for coordinate conversion");
  const CGFloat scale = getWindowScaleFactor();
  const CGPoint screen_point = CGPointMake(CGFloat(inX) / scale, CGFloat(inY) / scale);
  const CGPoint client_point = [uiview_ convertPoint:screen_point
                                fromCoordinateSpace:window_scene.coordinateSpace];
  outX = int32_t(std::lround(client_point.x * scale));
  outY = int32_t(std::lround(client_point.y * scale));
}

void GHOST_WindowIOS::clientToScreenIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  UIWindowScene *window_scene = rootWindow.windowScene;
  GHOST_ASSERT(window_scene != nil, "A UIWindowScene is required for coordinate conversion");
  const CGFloat scale = getWindowScaleFactor();
  const CGPoint client_point = CGPointMake(CGFloat(inX) / scale, CGFloat(inY) / scale);
  const CGPoint screen_point = [uiview_ convertPoint:client_point
                                toCoordinateSpace:window_scene.coordinateSpace];
  outX = int32_t(std::lround(screen_point.x * scale));
  outY = int32_t(std::lround(screen_point.y * scale));
}

/* called for event, when window leaves monitor to another */
void GHOST_WindowIOS::setNativePixelSize(void) {}

/**
 * \note Fullscreen switch is not actual fullscreen with display capture.
 * As this capture removes all OS X window manager features.
 *
 * Instead, the menu bar and the dock are hidden, and the window is made border-less and
 * enlarged. Thus, process switch, exposé, spaces, ... still work in fullscreen mode
 */
GHOST_TSuccess GHOST_WindowIOS::setState(GHOST_TWindowState /*state*/)
{
  // Ignore on iOS?
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setModifiedState(bool isUnsavedChanges)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  [pool drain];
  return GHOST_Window::setModifiedState(isUnsavedChanges);
}

GHOST_TSuccess GHOST_WindowIOS::setOrder(GHOST_TWindowOrder /*order*/)
{
  /* TODO: Support or deprecate for iOS */
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setOrder(): window invalid");

  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Drawing context

GHOST_Context *GHOST_WindowIOS::newDrawingContext(GHOST_TDrawingContextType type)
{

  if (type == GHOST_kDrawingContextTypeMetal) {

    GHOST_Context *context = new GHOST_ContextIOS(want_context_params_, uiview_, metal_view_);

    if (context->initializeDrawingContext())
      return context;
    else
      delete context;
  }

  return NULL;
}

#pragma mark invalidate

GHOST_TSuccess GHOST_WindowIOS::invalidate()
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::invalidate(): window invalid");
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Progress bar

GHOST_TSuccess GHOST_WindowIOS::setProgressBar(float /*progress*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::endProgressBar()
{
  return GHOST_kSuccess;
}

#pragma mark Cursor handling

void GHOST_WindowIOS::loadCursor(bool /*visible*/, GHOST_TStandardCursor /*shape*/) const {}

bool GHOST_WindowIOS::isDialog() const
{
  return is_dialog_;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorVisibility(bool visible)
{
  system_ios_->virtualPointer()->setBlenderVisibility(visible);
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorGrab(GHOST_TGrabCursorMode mode)
{
  /* Update the pointer shim first so restoring a hidden grab is not treated as another wrapped
   * motion event while GHOST_Window is still transitioning its shared grab state. */
  system_ios_->virtualPointer()->setGrabMode(mode);
  if (mode != GHOST_kGrabDisable && mode != GHOST_kGrabNormal) {
    system_ios_->getCursorPosition(cursor_grab_init_pos_[0], cursor_grab_init_pos_[1]);
    setCursorGrabAccum(0, 0);
  }
  else if (mode == GHOST_kGrabDisable) {
    if (cursor_grab_ == GHOST_kGrabHide) {
      system_ios_->setCursorPosition(cursor_grab_init_pos_[0], cursor_grab_init_pos_[1]);
    }
    setCursorGrabAccum(0, 0);
  }
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorShape(GHOST_TStandardCursor /*shape*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::hasCursorShape(GHOST_TStandardCursor /*shape*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCustomCursorShape(const uint8_t * /*bitmap*/,
                                                           const uint8_t * /*mask*/,
                                                           const int /*size*/[2],
                                                           const int /*hot_spot*/[2],
                                                           bool /*canInvertColor*/)
{
  /* Passthrough for iOS. */
  return GHOST_kSuccess;
}

uint16_t GHOST_WindowIOS::getDPIHint()
{
  /* Match the native iOS layer's touch-friendly UI scale. 96 DPI leaves
   * Blender's widgets and text too small on both iPhone and iPad, while 192
   * does not leave enough room for all menus. */
  return 144;
}

GHOST_TSuccess GHOST_WindowIOS::popupOnscreenKeyboard(
    const GHOST_KeyboardProperties &keyboard_properties)
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow popupOnscreenKeyboard:keyboard_properties];
}

GHOST_TSuccess GHOST_WindowIOS::hideOnscreenKeyboard()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow hideOnscreenKeyboard];
}

const char *GHOST_WindowIOS::getLastKeyboardString()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getLastKeyboardString];
}

UITextField *GHOST_WindowIOS::getUITextField()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getUITextField];
}

const GHOST_TabletData GHOST_WindowIOS::getTabletData()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getTabletData];
}

/* This is the size of the window pre-scaled */
CGSize GHOST_WindowIOS::getLogicalWindowSize()
{
  return metal_view_.bounds.size;
}

/* This is the size of the window post-scaled */
CGSize GHOST_WindowIOS::getNativeWindowSize()
{
  return metal_view_.drawableSize;
}

float GHOST_WindowIOS::getWindowScaleFactor() const
{
  const CGSize logical_size = metal_view_.bounds.size;
  const CGSize drawable_size = metal_view_.drawableSize;
  if (logical_size.width > 0.0f && drawable_size.width > 0.0f) {
    return float(drawable_size.width / logical_size.width);
  }
  if (logical_size.height > 0.0f && drawable_size.height > 0.0f) {
    return float(drawable_size.height / logical_size.height);
  }
  return metal_view_.contentScaleFactor > 0.0f ? metal_view_.contentScaleFactor : 1.0f;
}

/* Indicate that we want this window to be the next active one. */
void GHOST_WindowIOS::requestToActivateWindow()
{
  /* Check we're not already active. */
  if (system_ios_->current_active_window_ != this) {
    /* Replace any outstanding requests. */
    if (system_ios_->next_active_window_) {
      system_ios_->next_active_window_->requestToDeactivateWindow();
    }
    request_to_make_active_ = true;
    system_ios_->next_active_window_ = this;
  }
}

void GHOST_WindowIOS::requestToDeactivateWindow()
{
  if (system_ios_->next_active_window_ == this) {
    IOS_WINDOW_LOG(@"requestToDeactivateWindow(): Has something gone wrong? %p", this);
    system_ios_->next_active_window_ = nullptr;
  }
  request_to_make_active_ = false;
}

bool GHOST_WindowIOS::makeKeyWindow()
{
  if (!getValid()) {
    IOS_WINDOW_LOG(@"Failed to activate (invalid) con(%p) (win=%p)", getContext(), this);
    return false;
  }

  GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
  GHOST_ASSERT(rootWindow != nil, "GHOST_WindowIOS::makeKeyWindow() root window required");
  GHOST_ASSERT(context != nullptr, "GHOST_WindowIOS::makeKeyWindow() context required");
  GHOST_ASSERT(request_to_make_active_,
               "GHOST_WindowIOS::makeKeyWindow() must request activation first");

  /* Make window primary visible window. */
  [rootWindow makeKeyAndVisible];
  [rootWindow becomeFirstResponder];
  /* Enable the drawInMTKView() calls for this window. */
  metal_view_.paused = NO;
  noteActivity();

  IOS_WINDOW_LOG(@"Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 uiview_,
                 metal_view_,
                 getContext(),
                 this);

  system_ios_->current_active_window_ = this;
  system_ios_->virtualPointer()->attachWindow(this);
  /* Creating a secondary window marks it active in GHOST before UIKit switches windows. Closing
   * that window clears GHOST's active pointer. Restore it when UIKit makes the return window key,
   * otherwise the next top-level window has no owner and its close leaves the app without an
   * active render loop or software cursor. The initial window reaches this point before GHOST has
   * registered it, so only send an activation event for an already-managed return window. */
  if (system_ios_->validWindow(this) &&
      system_ios_->getWindowManager()->getActiveWindow() != this)
  {
    system_ios_->handleWindowEvent(GHOST_kEventWindowActivate, this);
  }
  is_active_window_ = true;
  request_to_make_active_ = false;
  return true;
}

void GHOST_WindowIOS::resignKeyWindow()
{
  GHOST_ASSERT(system_ios_->current_active_window_ == this,
               "GHOST_WindowIOS::resignKeyWindow(): Can only resign current active window");
  GHOST_ASSERT(is_active_window_,
               "GHOST_WindowIOS::resignKeyWindow(): Can't resign non active window");
  GHOST_ASSERT(!request_to_make_active_,
               "GHOST_WindowIOS::resignKeyWindow(): activation request outstanding");

  /* Disable the drawInMTKView() calls for this window. */
  metal_view_.paused = YES;
  /* Wait until any outstanding presents in flight are done. */
  while (uiview_controller_.beingPresented) {
  }
  [rootWindow resignKeyWindow];
  IOS_WINDOW_LOG(@"Resigning Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 uiview_,
                 metal_view_,
                 getContext(),
                 this);
  is_active_window_ = false;
  system_ios_->current_active_window_ = nullptr;
}

CGPoint GHOST_WindowIOS::scalePointToWindow(CGPoint &point)
{
  CGPoint scaled_point;
  scaled_point.x = point.x * getWindowScaleFactor();
  scaled_point.y = point.y * getWindowScaleFactor();
  return scaled_point;
}

#ifdef WITH_INPUT_IME
void GHOST_WindowIOS::beginIME(
    int32_t /*x*/, int32_t /*y*/, int32_t /*w*/, int32_t /*h*/, bool /*completed*/)
{
  /* Passthrough for iOS. */
}

void GHOST_WindowIOS::endIME()
{
  /* Passthrough for iOS. */
}
#endif /* WITH_INPUT_IME */
