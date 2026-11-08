/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** iOS stubs for the optional OpenUSD Boost.Python hook bridge. */

#include "usd_hook.hh"

#include "usd_api_hook.hh"

namespace blender::io::usd {

void USD_register_hook(std::unique_ptr<USDHook> /*hook*/) {}

void USD_unregister_hook(const USDHook * /*hook*/) {}

USDHook *USD_find_hook_name(const char[] /*idname*/)
{
  return nullptr;
}

void register_hook_converters() {}

void call_export_hooks(Depsgraph * /*depsgraph*/,
                       const USDHierarchyIterator * /*iter*/,
                       ReportList * /*reports*/)
{
}

void call_material_export_hooks(pxr::UsdStageRefPtr /*stage*/,
                                const Material * /*material*/,
                                const pxr::UsdShadeMaterial & /*usd_material*/,
                                const USDExportParams & /*export_params*/,
                                ReportList * /*reports*/)
{
}

void call_import_hooks(USDStageReader * /*archive*/, ReportList * /*reports*/) {}

bool have_material_import_hook(pxr::UsdStageRefPtr /*stage*/,
                               const pxr::UsdShadeMaterial & /*usd_material*/,
                               const USDImportParams & /*import_params*/,
                               ReportList * /*reports*/)
{
  return false;
}

bool call_material_import_hooks(pxr::UsdStageRefPtr /*stage*/,
                                Material * /*material*/,
                                const pxr::UsdShadeMaterial & /*usd_material*/,
                                const USDImportParams & /*import_params*/,
                                ReportList * /*reports*/)
{
  return false;
}

}  // namespace blender::io::usd
