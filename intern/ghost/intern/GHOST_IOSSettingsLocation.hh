/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Location of Blender's user settings inside the app's Files-visible documents.
 */

#pragma once

#ifdef __OBJC__

@class NSString;
@class NSURL;

/**
 * Prepare `<documents>/Settings`, the root of Blender's per-version user folders.
 *
 * When only the old hidden `Application Support/Blender` folder exists it is moved there once.
 * If that move fails, the old folder is returned so existing settings stay in use. The returned
 * folder also gets a README explaining how to bring settings from a computer, which names
 * `version`, the running Blender version such as 5.3.
 */
NSURL *GHOST_IOSSettings_prepareRoot(NSURL *documents_url,
                                     NSURL *legacy_root_url,
                                     NSString *version);

#endif
