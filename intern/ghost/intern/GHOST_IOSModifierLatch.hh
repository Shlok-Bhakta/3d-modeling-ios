/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Platform-neutral state for the on-screen Shift, Ctrl, Alt and Cmd keys.
 */

#pragma once

#include <cstdint>

enum class GHOST_IOSModifier : uint8_t {
  Shift,
  Control,
  Alt,
  Command,
};

constexpr int GHOST_IOS_MODIFIER_COUNT = 4;

enum class GHOST_IOSModifierMode : uint8_t {
  /** Not applied. */
  Off,
  /** A finger is on the key: applied immediately, like a hardware key. */
  Held,
  /** Tapped once: applied to the next pointer press, then cleared on release. */
  Latched,
  /** Double tapped: applied to every pointer press until tapped again. */
  Locked,
};

struct GHOST_IOSModifierChange {
  GHOST_IOSModifier modifier;
  bool down;
};

/**
 * Turns touches on the modifier keys and pointer presses into the key state Blender should see.
 *
 * A held key is down for as long as it is held. Latched and locked keys are only pressed while a
 * pointer button is down, so navigation gestures between clicks keep their normal meaning.
 */
class GHOST_IOSModifierLatch {
 public:
  /** A touch on a key shorter than this is a tap. */
  static constexpr double tap_seconds = 0.3;
  /** A second tap within this time of a latching tap locks the key. */
  static constexpr double double_tap_seconds = 0.4;

  void keyDown(const GHOST_IOSModifier modifier, const double timestamp_seconds)
  {
    Key &key = key_(modifier);
    key.held = true;
    key.used = false;
    key.held_since = timestamp_seconds;
  }

  void keyUp(const GHOST_IOSModifier modifier, const double timestamp_seconds)
  {
    Key &key = key_(modifier);
    if (!key.held) {
      return;
    }
    key.held = false;

    const bool tap = !key.used && timestamp_seconds - key.held_since <= tap_seconds;
    if (!tap) {
      /* Holding a key is momentary. Only a locked key survives being held. */
      if (key.mode != GHOST_IOSModifierMode::Locked) {
        key.mode = GHOST_IOSModifierMode::Off;
      }
      return;
    }

    switch (key.mode) {
      case GHOST_IOSModifierMode::Off:
        key.mode = GHOST_IOSModifierMode::Latched;
        key.latched_at = timestamp_seconds;
        break;
      case GHOST_IOSModifierMode::Latched:
        key.mode = timestamp_seconds - key.latched_at <= double_tap_seconds ?
                       GHOST_IOSModifierMode::Locked :
                       GHOST_IOSModifierMode::Off;
        break;
      case GHOST_IOSModifierMode::Locked:
      case GHOST_IOSModifierMode::Held:
        key.mode = GHOST_IOSModifierMode::Off;
        break;
    }
  }

  /** UIKit took the touch away, for example for a system gesture. */
  void keyCancelled(const GHOST_IOSModifier modifier)
  {
    Key &key = key_(modifier);
    key.held = false;
    if (key.mode != GHOST_IOSModifierMode::Locked) {
      key.mode = GHOST_IOSModifierMode::Off;
    }
  }

  /** Call before a pointer button press reaches Blender. */
  void pointerPressed()
  {
    pointer_down_ = true;
    for (Key &key : keys_) {
      if (key.held) {
        key.used = true;
      }
    }
  }

  /** Call after the last pointer button release reached Blender. */
  void pointerReleased()
  {
    pointer_down_ = false;
    for (Key &key : keys_) {
      if (key.mode == GHOST_IOSModifierMode::Latched) {
        key.mode = GHOST_IOSModifierMode::Off;
      }
    }
  }

  /** Turn every key off. Keys already sent are still released by #takeChanges. */
  void clear()
  {
    for (Key &key : keys_) {
      const bool sent = key.sent;
      key = Key();
      key.sent = sent;
    }
    pointer_down_ = false;
  }

  /** The state to show on the key. */
  GHOST_IOSModifierMode mode(const GHOST_IOSModifier modifier) const
  {
    const Key &key = keys_[index_(modifier)];
    return key.held ? GHOST_IOSModifierMode::Held : key.mode;
  }

  bool anyActive() const
  {
    for (int i = 0; i < GHOST_IOS_MODIFIER_COUNT; i++) {
      if (mode(GHOST_IOSModifier(i)) != GHOST_IOSModifierMode::Off) {
        return true;
      }
    }
    return false;
  }

  /** Whether Blender should currently see this modifier held. */
  bool wantsDown(const GHOST_IOSModifier modifier) const
  {
    const Key &key = keys_[index_(modifier)];
    if (key.held) {
      return true;
    }
    return pointer_down_ && (key.mode == GHOST_IOSModifierMode::Latched ||
                             key.mode == GHOST_IOSModifierMode::Locked);
  }

  /** Whether the key event for this modifier has been sent and not yet released. */
  bool sent(const GHOST_IOSModifier modifier) const
  {
    return keys_[index_(modifier)].sent;
  }

  /** Something else released the key in Blender, such as app activation. */
  void forgetSent(const GHOST_IOSModifier modifier)
  {
    key_(modifier).sent = false;
  }

  /**
   * Report the key presses and releases needed since the last call.
   * \return The number of entries written to \a changes.
   */
  int takeChanges(GHOST_IOSModifierChange changes[GHOST_IOS_MODIFIER_COUNT])
  {
    int count = 0;
    for (int i = 0; i < GHOST_IOS_MODIFIER_COUNT; i++) {
      const GHOST_IOSModifier modifier = GHOST_IOSModifier(i);
      const bool down = wantsDown(modifier);
      if (keys_[i].sent != down) {
        keys_[i].sent = down;
        changes[count++] = {modifier, down};
      }
    }
    return count;
  }

 private:
  struct Key {
    GHOST_IOSModifierMode mode = GHOST_IOSModifierMode::Off;
    bool held = false;
    /** A pointer button was pressed while the key was held. */
    bool used = false;
    bool sent = false;
    double held_since = 0.0;
    double latched_at = 0.0;
  };

  static int index_(const GHOST_IOSModifier modifier)
  {
    return int(modifier);
  }

  Key &key_(const GHOST_IOSModifier modifier)
  {
    return keys_[index_(modifier)];
  }

  Key keys_[GHOST_IOS_MODIFIER_COUNT];
  bool pointer_down_ = false;
};
