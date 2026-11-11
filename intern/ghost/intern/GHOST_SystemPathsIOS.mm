/* SPDX-FileCopyrightText: 2010 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#import <Foundation/Foundation.h>

#include <optional>
#include <string>

#include "GHOST_Debug.hh"
#include "GHOST_IOSSettingsLocation.hh"
#include "GHOST_SystemPathsCocoa.hh"

/* --------------------------------------------------------------------
 * Base directories retrieval.
 */

static const char *GetApplicationSupportDir(const char *versionstr,
                                            const NSSearchPathDomainMask mask,
                                            char *tempPath,
                                            const std::size_t len_tempPath)
{
  @autoreleasepool {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, mask, YES);

    if (paths.count == 0) {
      return nullptr;
    }
    NSString *basePath = [paths objectAtIndex:0];

    snprintf(tempPath,
             len_tempPath,
             "%s/Blender/%s",
             [basePath cStringUsingEncoding:NSASCIIStringEncoding],
             versionstr);
  }
  return tempPath;
}

const char *GHOST_SystemPathsCocoa::getSystemDir(int /* version */, const char *versionstr) const
{
  static char tempPath[512] = "";
  return GetApplicationSupportDir(versionstr, NSLocalDomainMask, tempPath, sizeof(tempPath));
}

/**
 * User settings live in `Documents/Settings` so they show up in the Files app, where people can
 * bring preferences, add-ons and extensions from a computer. The folder is resolved once, moving
 * the hidden `Application Support/Blender` folder used by earlier builds.
 */
static NSString *IOS_user_settings_root(const char *versionstr)
{
  static NSString *root_path = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    @autoreleasepool {
      NSFileManager *file_manager = [NSFileManager defaultManager];
      NSURL *documents_url = [file_manager URLsForDirectory:NSDocumentDirectory
                                                  inDomains:NSUserDomainMask]
                                 .firstObject;
      NSURL *support_url = [file_manager URLsForDirectory:NSApplicationSupportDirectory
                                                inDomains:NSUserDomainMask]
                               .firstObject;
      NSURL *legacy_url = [support_url URLByAppendingPathComponent:@"Blender" isDirectory:YES];
      NSURL *root_url = GHOST_IOSSettings_prepareRoot(
          documents_url, legacy_url, versionstr ? @(versionstr) : nil);
      root_path = [root_url.path copy];
    }
  });
  return root_path;
}

const char *GHOST_SystemPathsCocoa::getUserDir(int /* version */, const char *versionstr) const
{
  static char tempPath[512] = "";
  NSString *root_path = IOS_user_settings_root(versionstr);
  if (root_path == nil) {
    return nullptr;
  }
  snprintf(tempPath, sizeof(tempPath), "%s/%s", root_path.fileSystemRepresentation, versionstr);
  return tempPath;
}

std::optional<std::string> GHOST_SystemPathsCocoa::getUserSpecialDir(
    GHOST_TUserSpecialDirTypes type) const
{
  char tempPath[512] = "";
  @autoreleasepool {
    NSSearchPathDirectory ns_directory;

    switch (type) {
      case GHOST_kUserSpecialDirDesktop:
        ns_directory = NSDesktopDirectory;
        break;
      case GHOST_kUserSpecialDirDocuments:
        ns_directory = NSDocumentDirectory;
        break;
      case GHOST_kUserSpecialDirDownloads:
        ns_directory = NSDownloadsDirectory;
        break;
      case GHOST_kUserSpecialDirMusic:
        ns_directory = NSMusicDirectory;
        break;
      case GHOST_kUserSpecialDirPictures:
        ns_directory = NSPicturesDirectory;
        break;
      case GHOST_kUserSpecialDirVideos:
        ns_directory = NSMoviesDirectory;
        break;
      case GHOST_kUserSpecialDirCaches:
        ns_directory = NSCachesDirectory;
        break;
      default:
        GHOST_ASSERT(
            false,
            "GHOST_SystemPathsCocoa::getUserSpecialDir(): Invalid enum value for type parameter");
        return std::nullopt;
    }

    NSArray *paths = NSSearchPathForDirectoriesInDomains(ns_directory, NSUserDomainMask, YES);
    if (paths.count == 0) {
      return std::nullopt;
    }
    NSString *basePath = [paths objectAtIndex:0];

    const char *basePath_cstr = [basePath cStringUsingEncoding:NSASCIIStringEncoding];
    int basePath_len = strlen(basePath_cstr);

    basePath_len = MIN(basePath_len, sizeof(tempPath) - 1);
    memcpy(tempPath, basePath_cstr, basePath_len);
    tempPath[basePath_len] = '\0';
  }
  if (!tempPath[0]) {
    return std::nullopt;
  }
  return tempPath;
}

const char *GHOST_SystemPathsCocoa::getBinaryDir() const
{
  static char tempPath[512] = "";

  @autoreleasepool {
    NSString *basePath = [[NSBundle mainBundle] bundlePath];

    if (basePath == nil) {
      return nullptr;
    }

    const char *basePath_cstr = [basePath cStringUsingEncoding:NSASCIIStringEncoding];
    int basePath_len = strlen(basePath_cstr);

    basePath_len = MIN(basePath_len, sizeof(tempPath) - 1);
    memcpy(tempPath, basePath_cstr, basePath_len);
    tempPath[basePath_len] = '\0';
  }
  return tempPath;
}

void GHOST_SystemPathsCocoa::addToSystemRecentFiles(const char * /*filepath*/) const
{
  /* UIKit has no NSDocumentController-style recent-files service. */
}
