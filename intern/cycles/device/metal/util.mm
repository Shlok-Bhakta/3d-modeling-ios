/* SPDX-FileCopyrightText: 2021-2022 Blender Foundation
 *
 * SPDX-License-Identifier: Apache-2.0 */

#ifdef WITH_METAL

#  include "device/metal/util.h"
#  include "util/string.h"

#  include <TargetConditionals.h>
#  if TARGET_OS_OSX
#    include <IOKit/IOKitLib.h>
#  endif

CCL_NAMESPACE_BEGIN

string MetalInfo::get_device_name(id<MTLDevice> device)
{
  string device_name = [device.name UTF8String];

  /* Append the GPU core count so we can distinguish between GPU variants in benchmarks. */
  int gpu_core_count = get_apple_gpu_core_count(device);
  device_name += string_printf(gpu_core_count ? " (GPU - %d cores)" : " (GPU)", gpu_core_count);

  return device_name;
}

int MetalInfo::get_apple_gpu_core_count(id<MTLDevice> device)
{
  int core_count = 0;
#  if TARGET_OS_OSX
  io_service_t gpu_service = IOServiceGetMatchingService(
      kIOMainPortDefault, IORegistryEntryIDMatching(device.registryID));
  if (CFNumberRef numberRef = (CFNumberRef)IORegistryEntryCreateCFProperty(
          gpu_service, CFSTR("gpu-core-count"), nullptr, 0))
  {
    if (CFGetTypeID(numberRef) == CFNumberGetTypeID()) {
      CFNumberGetValue(numberRef, kCFNumberSInt32Type, &core_count);
    }
    CFRelease(numberRef);
  }
#  else
  (void)device;
#  endif
  return core_count;
}

AppleGPUArchitecture MetalInfo::get_apple_gpu_architecture(id<MTLDevice> device)
{
  const char *device_name = [device.name UTF8String];
  if (strstr(device_name, "M1")) {
    return APPLE_M1;
  }
  if (strstr(device_name, "M2")) {
    return get_apple_gpu_core_count(device) <= 10 ? APPLE_M2 : APPLE_M2_BIG;
  }
  if (strstr(device_name, "M3")) {
    return APPLE_M3;
  }
  return APPLE_UNKNOWN;
}

int MetalInfo::optimal_sort_partition_elements()
{
  if (auto *str = getenv("CYCLES_METAL_SORT_PARTITION_ELEMENTS")) {
    return atoi(str);
  }

  /* On M1 and M2 GPUs, we see better cache utilization if we partition the active indices before
   * sorting each partition by material. Partitioning into chunks of 65536 elements results in an
   * overall render time speedup of up to 15%. */

  return 65536;
}

const vector<id<MTLDevice>> &MetalInfo::get_usable_devices()
{
  static vector<id<MTLDevice>> usable_devices;
  static bool already_enumerated = false;

  if (already_enumerated) {
    return usable_devices;
  }

  metal_printf("Usable Metal devices:");
  for (id<MTLDevice> device in MTLCopyAllDevices()) {
    string device_name = get_device_name(device);
    bool usable = false;

#  if TARGET_OS_OSX
    /* NOTE: This @available check sets the Cycles minimum macOS version. */
    if (@available(macos 13.0, *)) {
      const char *device_name_char = [device.name UTF8String];
      if (!(strstr(device_name_char, "Intel") || strstr(device_name_char, "AMD")) &&
          strstr(device_name_char, "Apple"))
      {
        /* TODO: Implement a better way to identify device vendor instead of relying on name. */
        /* We only support Apple Silicon GPUs which all have unified memory, but explicitly check
         * just in case it ever changes. */
        usable = [device hasUnifiedMemory];
      }
    }
#  else
    /* Cycles relies on tier-2 argument buffers for its bindless kernel
     * resources. Real iOS Apple GPUs expose that tier, while the simulator
     * currently caps pipelines at 31 buffers and cannot compile the kernels. */
    usable = [device argumentBuffersSupport] == MTLArgumentBuffersTier2;
#  endif

    if (usable) {
      metal_printf("- %s", device_name.c_str());
      [device retain];
      usable_devices.push_back(device);
    }
    else {
      metal_printf("  (skipping \"%s\")", device_name.c_str());
    }
  }
  if (usable_devices.empty()) {
    metal_printf("   No usable Metal devices found");
  }
  already_enumerated = true;

  return usable_devices;
}

CCL_NAMESPACE_END

#endif /* WITH_METAL */
