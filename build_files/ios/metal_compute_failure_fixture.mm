/* SPDX-FileCopyrightText: 2026 Blender Authors
 * SPDX-License-Identifier: GPL-2.0-or-later */

/* Simulator-only fault injection at the real Metal pipeline creation boundary. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>

#include <atomic>

#if !TARGET_OS_SIMULATOR
#  error This fixture must never be linked into a device application.
#endif

using CreatePipeline = id (*)(id,
                             SEL,
                             MTLComputePipelineDescriptor *,
                             MTLPipelineOption,
                             MTLComputePipelineReflection **,
                             NSError **);
static CreatePipeline original_create;
static std::atomic<bool> enabled(false);
static std::atomic<int> failures(0);
static std::atomic<int> recovered_pipelines(0);

static id create_pipeline(id device,
                          SEL selector,
                          MTLComputePipelineDescriptor *descriptor,
                          MTLPipelineOption options,
                          MTLComputePipelineReflection **reflection,
                          NSError **error)
{
  if (enabled && [descriptor.label isEqualToString:@"eevee_ray_generate"]) {
    failures++;
    if (error) {
      *error = [NSError errorWithDomain:@"BlenderComputeRegression"
                                  code:1
                              userInfo:@{NSLocalizedDescriptionKey :
                                             @"Injected unsupported compute pipeline"}];
    }
    fprintf(stderr, "Injected Metal pipeline failure: eevee_ray_generate\n");
    return nil;
  }
  id pipeline = original_create(device, selector, descriptor, options, reflection, error);
  if (pipeline != nil && [descriptor.label isEqualToString:@"eevee_ray_generate"]) {
    recovered_pipelines++;
  }
  return pipeline;
}

extern "C" void blender_test_fail_ray_pipeline()
{
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  Method method = class_getInstanceMethod(
      object_getClass(device),
      @selector(newComputePipelineStateWithDescriptor:options:reflection:error:));
  original_create = reinterpret_cast<CreatePipeline>(
      method_setImplementation(method, reinterpret_cast<IMP>(create_pipeline)));
  enabled = true;
}

extern "C" void blender_test_restore_ray_pipeline()
{
  recovered_pipelines = 0;
  enabled = false;
}

extern "C" int blender_test_pipeline_failures()
{
  return failures.load();
}

extern "C" int blender_test_recovered_pipelines()
{
  return recovered_pipelines.load();
}
