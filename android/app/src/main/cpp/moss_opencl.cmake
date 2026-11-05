# The app opens the phone's public vendor driver directly. Never
# package a proprietary libOpenCL.so or select a CPU OpenCL device.
FetchContent_Declare(wb_cl_headers
    URL https://codeload.github.com/KhronosGroup/OpenCL-Headers/tar.gz/82f60316cc142e7b21dc1d8983b26de18858fbd9
    URL_HASH SHA256=7576bc8ba67af73ef30ae28096b4d19b953e7767960f24fba0e14d97e732f62d)
FetchContent_GetProperties(wb_cl_headers)
if(NOT wb_cl_headers_POPULATED)
    FetchContent_Populate(wb_cl_headers)
endif()
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/wb-cmake")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/wb-cmake/FindOpenCL.cmake"
    "set(OpenCL_FOUND TRUE)\nset(OpenCL_LIBRARIES dl)\nset(OpenCL_INCLUDE_DIRS \"${wb_cl_headers_SOURCE_DIR}\")\n")
list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_BINARY_DIR}/wb-cmake")
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL ON CACHE BOOL "" FORCE)
set(GGML_OPENCL_EMBED_KERNELS ON CACHE BOOL "" FORCE)
set(GGML_OPENCL_USE_ADRENO_KERNELS ON CACHE BOOL "" FORCE)
set(GGML_OPENCL_PROFILING ON CACHE BOOL "" FORCE)

function(wb_patch_opencl source)
    file(READ "${source}" contents)
    if(contents MATCHES "extern .C. void wb_moss_gpu_timing")
        return()
    endif()
    # Keep bounded aggregate hardware event timing; no CSVs or tensor data.
    string(FIND "${contents}" "    void write_profiling_info() {" start)
    string(FIND "${contents}" "    size_t get_kernel_workgroup_size" end)
    if(start EQUAL -1 OR end EQUAL -1)
        message(FATAL_ERROR "Pinned OpenCL profiling anchors changed")
    endif()
    string(SUBSTRING "${contents}" 0 ${start} before)
    string(SUBSTRING "${contents}" ${end} -1 after)
    set(contents "${before}    void write_profiling_info() {}\n\n${after}")
    string(REPLACE "            info.cmd_duration_ns            = cmd_end       - cmd_start;"
        "            info.cmd_duration_ns            = cmd_end       - cmd_start;\n            wb_moss_gpu_timing(cmd_end - cmd_start, 1);"
        contents "${contents}")
    string(REPLACE "        profiling_results.insert(profiling_results.end(),\n            std::make_move_iterator(profiling_info.begin()),\n            std::make_move_iterator(profiling_info.end()));"
        "" contents "${contents}")
    string(REPLACE "    CL_CHECK(clReleaseEvent(evt));\n}\n\n// Synchronizes"
        "    CL_CHECK(clReleaseEvent(evt));\n    backend_ctx->flush_profiling_batch();\n}\n\n// Synchronizes"
        contents "${contents}")
    file(WRITE "${source}" "#include <cstdint>\nextern \"C\" void wb_moss_gpu_timing(uint64_t, uint64_t);\n${contents}")
endfunction()

function(wb_patch_moss_loader source destination)
    file(READ "${source}" contents)
    # OpenCL GET_ROWS supports F32/F16, not Q5_K. Expand only the token table
    # before uploading it, preserving exact dequantized values and the GGUF.
    string(REPLACE "        tensor_names_.emplace_back(name);"
        "        if (std::getenv(\"MTD_DEVICE\") && std::strcmp(std::getenv(\"MTD_DEVICE\"), \"opencl\") == 0 && std::strcmp(name, \"token_embd.weight\") == 0) {\n            t->type = GGML_TYPE_F32; t->nb[0] = sizeof(float);\n            for (int d = 1; d < GGML_MAX_DIMS; ++d) t->nb[d] = t->nb[d-1] * t->ne[d-1];\n        }\n        tensor_names_.emplace_back(name);"
        contents "${contents}")
    string(REPLACE "        ggml_backend_tensor_set(t, stage.data(), 0, sz);"
        "        if (t->type == GGML_TYPE_F32 && gguf_get_tensor_type(gguf_, i) != GGML_TYPE_F32) {\n            const auto* traits = ggml_get_type_traits(gguf_get_tensor_type(gguf_, i));\n            if (!traits->to_float) { std::fclose(fp); return false; }\n            std::vector<float> expanded(ggml_nelements(t));\n            traits->to_float(stage.data(), expanded.data(), expanded.size());\n            ggml_backend_tensor_set(t, expanded.data(), 0, expanded.size() * sizeof(float));\n        } else { ggml_backend_tensor_set(t, stage.data(), 0, sz); }"
        contents "${contents}")
    file(WRITE "${destination}" "#include <cstdlib>\n${contents}")
endfunction()
