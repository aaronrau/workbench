// The Android vendor library is optional and never copied into the APK.
// Function types come from the pinned Khronos headers. Resolving directly avoids
// assuming the Android driver implements a desktop ICD dispatch table.
#pragma once
#define CL_TARGET_OPENCL_VERSION GGML_OPENCL_TARGET_VERSION
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#include <CL/cl.h>
#include <dlfcn.h>
#include <stdexcept>
#include <cstdio>
#include <cstdlib>
namespace wb {
inline void* opencl_driver() {
    static void* handle = []() {
        void* h = dlopen("libOpenCL.so", RTLD_NOW | RTLD_LOCAL);
        if (!h) h = dlopen("/vendor/lib64/libOpenCL.so", RTLD_NOW | RTLD_LOCAL);
        if (!h) throw std::runtime_error("OpenCL driver unavailable");
        return h;
    }();
    return handle;
}
template<typename T> T opencl_symbol(const char* name) {
    auto symbol = reinterpret_cast<T>(dlsym(opencl_driver(), name));
    if (!symbol) throw std::runtime_error("OpenCL driver missing required entry point");
    return symbol;
}
}
#define clBuildProgram(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clBuildProgram)>("clBuildProgram"); return fn; }())(__VA_ARGS__)
#define clCreateBuffer(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateBuffer)>("clCreateBuffer"); return fn; }())(__VA_ARGS__)
#define clCreateBufferWithProperties(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateBufferWithProperties)>("clCreateBufferWithProperties"); return fn; }())(__VA_ARGS__)
#define clCreateCommandQueue(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateCommandQueue)>("clCreateCommandQueue"); return fn; }())(__VA_ARGS__)
#define clCreateContext(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateContext)>("clCreateContext"); return fn; }())(__VA_ARGS__)
#define clCreateImage(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateImage)>("clCreateImage"); return fn; }())(__VA_ARGS__)
#define clCreateKernel(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateKernel)>("clCreateKernel"); return fn; }())(__VA_ARGS__)
#define clCreateProgramWithSource(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateProgramWithSource)>("clCreateProgramWithSource"); return fn; }())(__VA_ARGS__)
#define clCreateSubBuffer(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clCreateSubBuffer)>("clCreateSubBuffer"); return fn; }())(__VA_ARGS__)
#define clEnqueueBarrierWithWaitList(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clEnqueueBarrierWithWaitList)>("clEnqueueBarrierWithWaitList"); return fn; }())(__VA_ARGS__)
#define clEnqueueCopyBuffer(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clEnqueueCopyBuffer)>("clEnqueueCopyBuffer"); return fn; }())(__VA_ARGS__)
#define clEnqueueFillBuffer(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clEnqueueFillBuffer)>("clEnqueueFillBuffer"); return fn; }())(__VA_ARGS__)
#define clEnqueueMarkerWithWaitList(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clEnqueueMarkerWithWaitList)>("clEnqueueMarkerWithWaitList"); return fn; }())(__VA_ARGS__)
#define clEnqueueNDRangeKernel(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clEnqueueNDRangeKernel)>("clEnqueueNDRangeKernel"); return fn; }())(__VA_ARGS__)
#define clEnqueueReadBuffer(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clEnqueueReadBuffer)>("clEnqueueReadBuffer"); return fn; }())(__VA_ARGS__)
#define clEnqueueWriteBuffer(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clEnqueueWriteBuffer)>("clEnqueueWriteBuffer"); return fn; }())(__VA_ARGS__)
#define clFinish(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clFinish)>("clFinish"); return fn; }())(__VA_ARGS__)
#define clFlush(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clFlush)>("clFlush"); return fn; }())(__VA_ARGS__)
#define clGetDeviceIDs(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetDeviceIDs)>("clGetDeviceIDs"); return fn; }())(__VA_ARGS__)
#define clGetDeviceInfo(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetDeviceInfo)>("clGetDeviceInfo"); return fn; }())(__VA_ARGS__)
#define clGetEventProfilingInfo(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetEventProfilingInfo)>("clGetEventProfilingInfo"); return fn; }())(__VA_ARGS__)
#define clGetKernelInfo(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetKernelInfo)>("clGetKernelInfo"); return fn; }())(__VA_ARGS__)
#define clGetKernelSubGroupInfo(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetKernelSubGroupInfo)>("clGetKernelSubGroupInfo"); return fn; }())(__VA_ARGS__)
#define clGetKernelWorkGroupInfo(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetKernelWorkGroupInfo)>("clGetKernelWorkGroupInfo"); return fn; }())(__VA_ARGS__)
#define clGetPlatformIDs(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetPlatformIDs)>("clGetPlatformIDs"); return fn; }())(__VA_ARGS__)
#define clGetPlatformInfo(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetPlatformInfo)>("clGetPlatformInfo"); return fn; }())(__VA_ARGS__)
#define clGetProgramBuildInfo(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clGetProgramBuildInfo)>("clGetProgramBuildInfo"); return fn; }())(__VA_ARGS__)
#define clReleaseEvent(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clReleaseEvent)>("clReleaseEvent"); return fn; }())(__VA_ARGS__)
#define clReleaseMemObject(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clReleaseMemObject)>("clReleaseMemObject"); return fn; }())(__VA_ARGS__)
#define clReleaseProgram(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clReleaseProgram)>("clReleaseProgram"); return fn; }())(__VA_ARGS__)
#define clSetKernelArg(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clSetKernelArg)>("clSetKernelArg"); return fn; }())(__VA_ARGS__)
#define clWaitForEvents(...) ([]() { static auto fn = wb::opencl_symbol<decltype(&::clWaitForEvents)>("clWaitForEvents"); return fn; }())(__VA_ARGS__)
