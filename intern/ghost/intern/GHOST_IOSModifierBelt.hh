/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Native on-screen Shift, Ctrl, Alt and Cmd keys for touch and Apple Pencil.
 */

#pragma once

#include "GHOST_IOSModifierLatch.hh"

#ifdef __OBJC__

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class UIView;

/** Receives touches on the belt's keys. Timestamps are `UITouch.timestamp` seconds. */
@protocol GHOSTIOSModifierBeltDelegate <NSObject>
- (void)modifierBeltKey:(GHOST_IOSModifier)modifier
                   down:(BOOL)down
              timestamp:(NSTimeInterval)timestamp;
- (void)modifierBeltKeyCancelled:(GHOST_IOSModifier)modifier;
/** The belt was hidden, for example because a hardware keyboard connected. */
- (void)modifierBeltDidHide;
@end

/**
 * Add the belt to \a input_view. It starts collapsed to a small handle in the corner the user
 * last chose. The delegate is not retained.
 */
NSObject *GHOST_IOSModifierBelt_create(UIView *input_view,
                                       id<GHOSTIOSModifierBeltDelegate> delegate);
void GHOST_IOSModifierBelt_destroy(NSObject *belt);
bool GHOST_IOSModifierBelt_containsView(NSObject *belt, UIView *view);
/** Show each key's state, indexed by #GHOST_IOSModifier. */
void GHOST_IOSModifierBelt_setModes(NSObject *belt,
                                    const GHOST_IOSModifierMode modes[GHOST_IOS_MODIFIER_COUNT]);
/**
 * Fade the belt while the app-drawn finger cursor is over it, so the target under the belt stays
 * visible. \a point is in \a input_view points.
 */
void GHOST_IOSModifierBelt_setCursor(NSObject *belt, CGPoint point, bool visible);

#endif
