/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Native on-screen Shift, Ctrl, Alt and Cmd keys for touch and Apple Pencil.
 *
 * The belt is a small handle that can be dragged to any corner of the screen. Tapping it shows
 * the keys. Each key can be held like a hardware key, tapped to apply to the next click, or double
 * tapped to stay on. The key logic lives in #GHOST_IOSModifierLatch; this file is only the view.
 */

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

#include "GHOST_IOSModifierBelt.hh"

#include <cstdlib>
#include <cstring>

/** Corners, stored in user defaults. */
enum {
  GHOST_IOS_BELT_TOP_LEFT = 0,
  GHOST_IOS_BELT_TOP_RIGHT = 1,
  GHOST_IOS_BELT_BOTTOM_LEFT = 2,
  GHOST_IOS_BELT_BOTTOM_RIGHT = 3,
};

static NSString *const GHOST_IOSModifierBeltCorner = @"GHOST_IOSModifierBeltCorner";

static constexpr CGFloat belt_height = 52.0f;
static constexpr CGFloat belt_padding = 4.0f;
static constexpr CGFloat handle_size = 44.0f;
static constexpr CGFloat key_width = 58.0f;
static constexpr CGFloat edge_inset = 12.0f;
/** Keep the bottom corners clear of Blender's status bar. */
static constexpr CGFloat bottom_inset = 40.0f;
/** Opacity while the app's finger cursor is over the belt. */
static constexpr CGFloat cursor_over_alpha = 0.3f;

struct GHOST_IOSModifierKeyInfo {
  GHOST_IOSModifier modifier;
  NSString *symbol;
  NSString *title;
  NSString *identifier;
};

static const GHOST_IOSModifierKeyInfo GHOST_IOS_MODIFIER_KEYS[GHOST_IOS_MODIFIER_COUNT] = {
    {GHOST_IOSModifier::Shift, @"shift", @"Shift", @"blender_modifier_shift"},
    {GHOST_IOSModifier::Control, @"control", @"Ctrl", @"blender_modifier_control"},
    {GHOST_IOSModifier::Alt, @"option", @"Alt", @"blender_modifier_alt"},
    {GHOST_IOSModifier::Command, @"command", @"Cmd", @"blender_modifier_command"},
};

static os_log_t GHOST_IOSModifierBeltLog()
{
  static os_log_t log = os_log_create("org.blender.ios", "modifier-belt");
  return log;
}

static NSString *GHOST_IOSModifierModeName(const GHOST_IOSModifierMode mode)
{
  switch (mode) {
    case GHOST_IOSModifierMode::Held:
      return @"held";
    case GHOST_IOSModifierMode::Latched:
      return @"latched";
    case GHOST_IOSModifierMode::Locked:
      return @"locked";
    case GHOST_IOSModifierMode::Off:
      break;
  }
  return @"off";
}

static UIImage *GHOST_IOSModifierSymbol(NSString *name, const CGFloat size)
{
  UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
      configurationWithPointSize:size
                          weight:UIImageSymbolWeightSemibold];
  return [UIImage systemImageNamed:name withConfiguration:config];
}

/* -------------------------------------------------------------------- */
/** \name Key
 * \{ */

@interface GHOSTIOSModifierKeyView : UIView {
  GHOST_IOSModifier modifier_;
  GHOST_IOSModifierMode mode_;
  id<GHOSTIOSModifierBeltDelegate> delegate_;
  UIImageView *icon_;
  UILabel *label_;
  UIView *lock_bar_;
  /** Not retained: only compared against the touches UIKit delivers. */
  UITouch *tracked_touch_;
}
- (instancetype)initWithKey:(const GHOST_IOSModifierKeyInfo &)info
                   delegate:(id<GHOSTIOSModifierBeltDelegate>)delegate;
- (void)setMode:(GHOST_IOSModifierMode)mode;
- (GHOST_IOSModifier)modifier;
@end

@implementation GHOSTIOSModifierKeyView

- (instancetype)initWithKey:(const GHOST_IOSModifierKeyInfo &)info
                   delegate:(id<GHOSTIOSModifierBeltDelegate>)delegate
{
  self = [super initWithFrame:CGRectZero];
  if (self == nil) {
    return nil;
  }
  modifier_ = info.modifier;
  mode_ = GHOST_IOSModifierMode::Off;
  delegate_ = delegate;
  tracked_touch_ = nil;

  self.translatesAutoresizingMaskIntoConstraints = NO;
  self.layer.cornerRadius = 12.0f;
  self.layer.cornerCurve = kCACornerCurveContinuous;
  self.isAccessibilityElement = YES;
  self.accessibilityTraits = UIAccessibilityTraitButton;
  self.accessibilityLabel = info.title;
  self.accessibilityIdentifier = info.identifier;
  self.accessibilityHint = @"Hold, tap for the next click, or double tap to keep on";

  icon_ = [[UIImageView alloc] initWithImage:GHOST_IOSModifierSymbol(info.symbol, 15.0f)];
  icon_.translatesAutoresizingMaskIntoConstraints = NO;
  icon_.contentMode = UIViewContentModeCenter;
  icon_.tintColor = UIColor.whiteColor;

  label_ = [[UILabel alloc] init];
  label_.translatesAutoresizingMaskIntoConstraints = NO;
  label_.text = info.title;
  label_.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightSemibold];
  label_.textColor = UIColor.whiteColor;
  label_.textAlignment = NSTextAlignmentCenter;

  /* Like the caps lock bar on the software keyboard. */
  lock_bar_ = [[UIView alloc] init];
  lock_bar_.translatesAutoresizingMaskIntoConstraints = NO;
  lock_bar_.backgroundColor = UIColor.whiteColor;
  lock_bar_.layer.cornerRadius = 1.0f;
  lock_bar_.hidden = YES;

  [self addSubview:icon_];
  [self addSubview:label_];
  [self addSubview:lock_bar_];
  [NSLayoutConstraint activateConstraints:@[
    [self.widthAnchor constraintEqualToConstant:key_width],
    [self.heightAnchor constraintEqualToConstant:handle_size],
    [icon_.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [icon_.topAnchor constraintEqualToAnchor:self.topAnchor constant:5.0f],
    [label_.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [label_.topAnchor constraintEqualToAnchor:icon_.bottomAnchor constant:1.0f],
    [lock_bar_.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [lock_bar_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-3.0f],
    [lock_bar_.widthAnchor constraintEqualToConstant:14.0f],
    [lock_bar_.heightAnchor constraintEqualToConstant:2.0f],
  ]];
  [self setMode:GHOST_IOSModifierMode::Off];
  return self;
}

- (void)dealloc
{
  [icon_ release];
  [label_ release];
  [lock_bar_ release];
  [super dealloc];
}

- (GHOST_IOSModifier)modifier
{
  return modifier_;
}

- (void)setMode:(GHOST_IOSModifierMode)mode
{
  mode_ = mode;
  switch (mode) {
    case GHOST_IOSModifierMode::Off:
      self.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.10f];
      break;
    case GHOST_IOSModifierMode::Latched:
      self.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.5f];
      break;
    case GHOST_IOSModifierMode::Held:
    case GHOST_IOSModifierMode::Locked:
      self.backgroundColor = UIColor.systemBlueColor;
      break;
  }
  lock_bar_.hidden = mode != GHOST_IOSModifierMode::Locked;
  self.accessibilityValue = GHOST_IOSModifierModeName(mode);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  (void)event;
  if (tracked_touch_ != nil) {
    return;
  }
  tracked_touch_ = touches.anyObject;
  [delegate_ modifierBeltKey:modifier_ down:YES timestamp:tracked_touch_.timestamp];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  (void)event;
  if (tracked_touch_ == nil || ![touches containsObject:tracked_touch_]) {
    return;
  }
  const NSTimeInterval timestamp = tracked_touch_.timestamp;
  tracked_touch_ = nil;
  [delegate_ modifierBeltKey:modifier_ down:NO timestamp:timestamp];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  (void)event;
  if (tracked_touch_ == nil || ![touches containsObject:tracked_touch_]) {
    return;
  }
  tracked_touch_ = nil;
  [delegate_ modifierBeltKeyCancelled:modifier_];
}

- (void)cancelTracking
{
  if (tracked_touch_ != nil) {
    tracked_touch_ = nil;
    [delegate_ modifierBeltKeyCancelled:modifier_];
  }
}

- (BOOL)accessibilityActivate
{
  /* VoiceOver activation is a tap: apply the key to the next click. */
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  [delegate_ modifierBeltKey:modifier_ down:YES timestamp:now];
  [delegate_ modifierBeltKey:modifier_ down:NO timestamp:now];
  return YES;
}

@end

/** \} */

/* -------------------------------------------------------------------- */
/** \name Belt
 * \{ */

@interface GHOSTIOSModifierBeltView : UIView {
  id<GHOSTIOSModifierBeltDelegate> delegate_;
  UIVisualEffectView *background_;
  UIStackView *stack_;
  UIView *handle_;
  UIImageView *handle_icon_;
  NSArray<GHOSTIOSModifierKeyView *> *keys_;
  NSArray<NSLayoutConstraint *> *corner_constraints_;
  UIPanGestureRecognizer *pan_;
  UITapGestureRecognizer *tap_;
  id keyboard_connect_observer_;
  id keyboard_disconnect_observer_;
  NSInteger corner_;
  GHOST_IOSModifierMode modes_[GHOST_IOS_MODIFIER_COUNT];
  BOOL expanded_;
  BOOL cursor_over_;
}
- (instancetype)initWithInputView:(UIView *)input_view
                         delegate:(id<GHOSTIOSModifierBeltDelegate>)delegate;
- (void)teardown;
- (void)setModes:(const GHOST_IOSModifierMode *)modes;
- (void)setCursor:(CGPoint)point visible:(bool)visible;
@end

@implementation GHOSTIOSModifierBeltView

- (instancetype)initWithInputView:(UIView *)input_view
                         delegate:(id<GHOSTIOSModifierBeltDelegate>)delegate
{
  self = [super initWithFrame:CGRectZero];
  if (self == nil) {
    return nil;
  }
  delegate_ = delegate;
  expanded_ = NO;
  cursor_over_ = NO;
  for (GHOST_IOSModifierMode &mode : modes_) {
    mode = GHOST_IOSModifierMode::Off;
  }
  corner_constraints_ = nil;

  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  corner_ = [defaults objectForKey:GHOST_IOSModifierBeltCorner] != nil ?
                [defaults integerForKey:GHOST_IOSModifierBeltCorner] :
                GHOST_IOS_BELT_BOTTOM_RIGHT;
  corner_ = MAX(GHOST_IOS_BELT_TOP_LEFT, MIN(GHOST_IOS_BELT_BOTTOM_RIGHT, corner_));

  self.translatesAutoresizingMaskIntoConstraints = NO;
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  self.accessibilityIdentifier = @"blender_modifier_belt";
  self.layer.shadowColor = UIColor.blackColor.CGColor;
  self.layer.shadowOpacity = 0.3f;
  self.layer.shadowRadius = 8.0f;
  self.layer.shadowOffset = CGSizeMake(0.0f, 2.0f);

  background_ = [[UIVisualEffectView alloc]
      initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
  background_.translatesAutoresizingMaskIntoConstraints = NO;
  background_.layer.cornerRadius = belt_height * 0.5f;
  background_.layer.cornerCurve = kCACornerCurveContinuous;
  background_.clipsToBounds = YES;
  background_.userInteractionEnabled = NO;
  [self addSubview:background_];

  handle_ = [[UIView alloc] init];
  handle_.translatesAutoresizingMaskIntoConstraints = NO;
  handle_.layer.cornerRadius = handle_size * 0.5f;
  handle_.isAccessibilityElement = YES;
  handle_.accessibilityTraits = UIAccessibilityTraitButton;
  handle_.accessibilityLabel = @"Modifier keys";
  handle_.accessibilityHint = @"Tap to show Shift, Ctrl, Alt and Cmd. Drag to move to another corner.";
  handle_.accessibilityIdentifier = @"blender_modifier_belt_handle";
  handle_icon_ = [[UIImageView alloc] init];
  handle_icon_.translatesAutoresizingMaskIntoConstraints = NO;
  handle_icon_.contentMode = UIViewContentModeCenter;
  handle_icon_.tintColor = UIColor.whiteColor;
  [handle_ addSubview:handle_icon_];

  NSMutableArray<GHOSTIOSModifierKeyView *> *keys = [NSMutableArray array];
  for (const GHOST_IOSModifierKeyInfo &info : GHOST_IOS_MODIFIER_KEYS) {
    GHOSTIOSModifierKeyView *key = [[[GHOSTIOSModifierKeyView alloc] initWithKey:info
                                                                         delegate:delegate]
        autorelease];
    key.hidden = YES;
    [keys addObject:key];
  }
  keys_ = [keys copy];

  stack_ = [[UIStackView alloc] init];
  stack_.translatesAutoresizingMaskIntoConstraints = NO;
  stack_.axis = UILayoutConstraintAxisHorizontal;
  stack_.alignment = UIStackViewAlignmentCenter;
  stack_.spacing = belt_padding;
  [self addSubview:stack_];

  [NSLayoutConstraint activateConstraints:@[
    [background_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [background_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [background_.topAnchor constraintEqualToAnchor:self.topAnchor],
    [background_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [stack_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:belt_padding],
    [stack_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-belt_padding],
    [stack_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [self.heightAnchor constraintEqualToConstant:belt_height],
    [handle_.widthAnchor constraintEqualToConstant:handle_size],
    [handle_.heightAnchor constraintEqualToConstant:handle_size],
    [handle_icon_.centerXAnchor constraintEqualToAnchor:handle_.centerXAnchor],
    [handle_icon_.centerYAnchor constraintEqualToAnchor:handle_.centerYAnchor],
  ]];

  tap_ = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
  pan_ = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
  pan_.maximumNumberOfTouches = 1;
  [handle_ addGestureRecognizer:tap_];
  [handle_ addGestureRecognizer:pan_];

  [input_view addSubview:self];
  [self arrangeForCorner];
  [self activateCornerConstraints];
  [self updateHandle];

  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  GHOSTIOSModifierBeltView *belt = self;
  void (^keyboard_changed)(NSNotification *) = ^(NSNotification *) {
    [belt updateKeyboardVisibility];
  };
  keyboard_connect_observer_ = [[center addObserverForName:GCKeyboardDidConnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:keyboard_changed] retain];
  keyboard_disconnect_observer_ = [[center addObserverForName:GCKeyboardDidDisconnectNotification
                                                       object:nil
                                                        queue:NSOperationQueue.mainQueue
                                                   usingBlock:keyboard_changed] retain];
  [self updateKeyboardVisibility];
  return self;
}

- (void)teardown
{
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  if (keyboard_connect_observer_ != nil) {
    [center removeObserver:keyboard_connect_observer_];
    [keyboard_connect_observer_ release];
    keyboard_connect_observer_ = nil;
  }
  if (keyboard_disconnect_observer_ != nil) {
    [center removeObserver:keyboard_disconnect_observer_];
    [keyboard_disconnect_observer_ release];
    keyboard_disconnect_observer_ = nil;
  }
  [handle_ removeGestureRecognizer:tap_];
  [handle_ removeGestureRecognizer:pan_];
  delegate_ = nil;
  [self removeFromSuperview];
}

- (void)dealloc
{
  [background_ release];
  [stack_ release];
  [handle_ release];
  [handle_icon_ release];
  [keys_ release];
  [corner_constraints_ release];
  [pan_ release];
  [tap_ release];
  [super dealloc];
}

- (BOOL)isLeftCorner
{
  return corner_ == GHOST_IOS_BELT_TOP_LEFT || corner_ == GHOST_IOS_BELT_BOTTOM_LEFT;
}

- (BOOL)isTopCorner
{
  return corner_ == GHOST_IOS_BELT_TOP_LEFT || corner_ == GHOST_IOS_BELT_TOP_RIGHT;
}

/** Keep the handle against the screen edge so the keys open towards the middle. */
- (void)arrangeForCorner
{
  for (UIView *view in [[stack_.arrangedSubviews copy] autorelease]) {
    [stack_ removeArrangedSubview:view];
    [view removeFromSuperview];
  }
  if ([self isLeftCorner]) {
    [stack_ addArrangedSubview:handle_];
  }
  for (GHOSTIOSModifierKeyView *key in keys_) {
    [stack_ addArrangedSubview:key];
  }
  if (![self isLeftCorner]) {
    [stack_ addArrangedSubview:handle_];
  }
}

- (void)activateCornerConstraints
{
  UIView *parent = self.superview;
  if (parent == nil) {
    return;
  }
  if (corner_constraints_ != nil) {
    [NSLayoutConstraint deactivateConstraints:corner_constraints_];
    [corner_constraints_ release];
  }
  UILayoutGuide *safe_area = parent.safeAreaLayoutGuide;
  NSLayoutConstraint *horizontal =
      [self isLeftCorner] ?
          [self.leadingAnchor constraintEqualToAnchor:safe_area.leadingAnchor
                                             constant:edge_inset] :
          [self.trailingAnchor constraintEqualToAnchor:safe_area.trailingAnchor
                                              constant:-edge_inset];
  NSLayoutConstraint *vertical =
      [self isTopCorner] ?
          [self.topAnchor constraintEqualToAnchor:safe_area.topAnchor constant:edge_inset] :
          [self.bottomAnchor constraintEqualToAnchor:safe_area.bottomAnchor
                                            constant:-bottom_inset];
  corner_constraints_ = [@[ horizontal, vertical ] retain];
  [NSLayoutConstraint activateConstraints:corner_constraints_];
}

- (void)updateHandle
{
  NSString *symbol = @"keyboard";
  bool any_active = false;
  if (expanded_) {
    symbol = [self isLeftCorner] ? @"chevron.left" : @"chevron.right";
  }
  else {
    /* Show which key is on while the keys are tucked away. */
    for (const GHOST_IOSModifierKeyInfo &info : GHOST_IOS_MODIFIER_KEYS) {
      if (modes_[int(info.modifier)] != GHOST_IOSModifierMode::Off) {
        symbol = info.symbol;
        any_active = true;
        break;
      }
    }
  }
  handle_icon_.image = GHOST_IOSModifierSymbol(symbol, 18.0f);
  handle_.backgroundColor = any_active ? UIColor.systemBlueColor : UIColor.clearColor;
  handle_.accessibilityValue = expanded_ ? @"expanded" : @"collapsed";
}

- (void)setExpanded:(BOOL)expanded
{
  if (expanded_ == expanded) {
    return;
  }
  expanded_ = expanded;
  if (!expanded) {
    /* A finger still on a key must not stay held once the key is gone. */
    for (GHOSTIOSModifierKeyView *key in keys_) {
      [key cancelTracking];
    }
  }
  [UIView animateWithDuration:0.25
                        delay:0.0
       usingSpringWithDamping:0.9f
        initialSpringVelocity:0.0f
                      options:UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     for (GHOSTIOSModifierKeyView *key in keys_) {
                       key.hidden = !expanded;
                       key.alpha = expanded ? 1.0f : 0.0f;
                     }
                     [self.superview layoutIfNeeded];
                   }
                   completion:nil];
  [self updateHandle];
}

- (void)handleTap:(UITapGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateEnded) {
    [self setExpanded:!expanded_];
  }
}

- (void)handlePan:(UIPanGestureRecognizer *)sender
{
  UIView *parent = self.superview;
  if (parent == nil) {
    return;
  }
  const CGPoint translation = [sender translationInView:parent];
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    self.transform = CGAffineTransformMakeTranslation(translation.x, translation.y);
    return;
  }
  if (sender.state != UIGestureRecognizerStateEnded &&
      sender.state != UIGestureRecognizerStateCancelled)
  {
    return;
  }

  /* Snap to the corner of the quarter the belt was dropped in. */
  const CGRect dropped = self.frame;
  const CGRect safe = parent.safeAreaLayoutGuide.layoutFrame;
  const CGPoint center = CGPointMake(CGRectGetMidX(dropped), CGRectGetMidY(dropped));
  const BOOL left = center.x < CGRectGetMidX(safe);
  const BOOL top = center.y < CGRectGetMidY(safe);
  corner_ = top ? (left ? GHOST_IOS_BELT_TOP_LEFT : GHOST_IOS_BELT_TOP_RIGHT) :
                  (left ? GHOST_IOS_BELT_BOTTOM_LEFT : GHOST_IOS_BELT_BOTTOM_RIGHT);
  [NSUserDefaults.standardUserDefaults setInteger:corner_ forKey:GHOST_IOSModifierBeltCorner];

  self.transform = CGAffineTransformIdentity;
  [self arrangeForCorner];
  [self activateCornerConstraints];
  [self updateHandle];
  [parent layoutIfNeeded];
  /* Start the animation where the finger let go. */
  const CGRect settled = self.frame;
  self.transform = CGAffineTransformMakeTranslation(CGRectGetMinX(dropped) - CGRectGetMinX(settled),
                                                    CGRectGetMinY(dropped) - CGRectGetMinY(settled));
  [UIView animateWithDuration:0.35
                        delay:0.0
       usingSpringWithDamping:0.82f
        initialSpringVelocity:0.0f
                      options:UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     self.transform = CGAffineTransformIdentity;
                   }
                   completion:nil];
}

- (void)setModes:(const GHOST_IOSModifierMode *)modes
{
  for (GHOSTIOSModifierKeyView *key in keys_) {
    const int index = int(key.modifier);
    modes_[index] = modes[index];
    [key setMode:modes_[index]];
  }
  [self updateHandle];
}

- (void)setCursor:(CGPoint)point visible:(bool)visible
{
  const BOOL over = visible && !self.hidden &&
                    CGRectContainsPoint(CGRectInset(self.frame, -6.0f, -6.0f), point);
  if (over == cursor_over_) {
    return;
  }
  cursor_over_ = over;
  [UIView animateWithDuration:0.15
                        delay:0.0
                      options:UIViewAnimationOptionAllowUserInteraction |
                              UIViewAnimationOptionBeginFromCurrentState
                   animations:^{
                     self.alpha = over ? cursor_over_alpha : 1.0f;
                   }
                   completion:nil];
}

- (void)updateKeyboardVisibility
{
  /* `GHOST_IOS_MODIFIER_BELT=always` keeps the keys with a keyboard attached. The Simulator
   * always reports one, so UI tests use this too. */
  const char *belt_mode = getenv("GHOST_IOS_MODIFIER_BELT");
  const bool always = belt_mode != nullptr && strcmp(belt_mode, "always") == 0;
  const BOOL hide = !always && GCKeyboard.coalescedKeyboard != nil;
  if (self.hidden == hide) {
    return;
  }
  os_log_info(GHOST_IOSModifierBeltLog(),
              "Modifier keys %{public}s: hardware keyboard %{public}s",
              hide ? "hidden" : "shown",
              hide ? "connected" : "disconnected");
  self.hidden = hide;
  if (hide) {
    [self setExpanded:NO];
    [delegate_ modifierBeltDidHide];
  }
}

@end

/** \} */

/* -------------------------------------------------------------------- */
/** \name C API
 * \{ */

NSObject *GHOST_IOSModifierBelt_create(UIView *input_view,
                                       id<GHOSTIOSModifierBeltDelegate> delegate)
{
  if (input_view == nil) {
    return nil;
  }
  return [[GHOSTIOSModifierBeltView alloc] initWithInputView:input_view delegate:delegate];
}

void GHOST_IOSModifierBelt_destroy(NSObject *belt)
{
  if (belt == nil) {
    return;
  }
  [(GHOSTIOSModifierBeltView *)belt teardown];
  [belt release];
}

bool GHOST_IOSModifierBelt_containsView(NSObject *belt, UIView *view)
{
  if (belt == nil || view == nil) {
    return false;
  }
  return [view isDescendantOfView:(GHOSTIOSModifierBeltView *)belt];
}

void GHOST_IOSModifierBelt_setModes(NSObject *belt,
                                    const GHOST_IOSModifierMode modes[GHOST_IOS_MODIFIER_COUNT])
{
  [(GHOSTIOSModifierBeltView *)belt setModes:modes];
}

void GHOST_IOSModifierBelt_setCursor(NSObject *belt, CGPoint point, bool visible)
{
  [(GHOSTIOSModifierBeltView *)belt setCursor:point visible:visible];
}

/** \} */
