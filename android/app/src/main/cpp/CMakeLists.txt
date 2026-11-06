cmake_minimum_required(VERSION 3.22.1)

project(workbench_lc3 LANGUAGES C CXX)

set(LIBLC3_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/liblc3")

add_library(
    workbench_lc3
    SHARED
    workbench_lc3.cpp
    "${LIBLC3_DIR}/src/attdet.c"
    "${LIBLC3_DIR}/src/bits.c"
    "${LIBLC3_DIR}/src/bwdet.c"
    "${LIBLC3_DIR}/src/energy.c"
    "${LIBLC3_DIR}/src/lc3.c"
    "${LIBLC3_DIR}/src/ltpf.c"
    "${LIBLC3_DIR}/src/mdct.c"
    "${LIBLC3_DIR}/src/plc.c"
    "${LIBLC3_DIR}/src/sns.c"
    "${LIBLC3_DIR}/src/spec.c"
    "${LIBLC3_DIR}/src/tables.c"
    "${LIBLC3_DIR}/src/tns.c"
)

target_include_directories(
    workbench_lc3
    PRIVATE
    "${LIBLC3_DIR}/include"
    "${LIBLC3_DIR}/src"
)

target_compile_options(workbench_lc3 PRIVATE -O3 -ffast-math)

find_library(log_library log)
target_link_libraries(workbench_lc3 PRIVATE "${log_library}")

# A pinned native runtime. MOSS has its own process and never loads Sherpa or
# LiteRT-LM. Keep upstream sources in the build cache, not generated repo files.
include(FetchContent)
include("${CMAKE_CURRENT_SOURCE_DIR}/moss_opencl.cmake")
if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_Declare(workbench_ggml
    URL https://codeload.github.com/ggml-org/ggml/tar.gz/eced84c86f8b012c752c016f7fe789adea168e1e
    URL_HASH SHA256=8036f930dbe909affbcecdda7137d671520764d4396962d2b9c3df476cb29cb0)
FetchContent_GetProperties(workbench_ggml)
if(NOT workbench_ggml_POPULATED)
    FetchContent_Populate(workbench_ggml)
endif()
wb_patch_opencl("${workbench_ggml_SOURCE_DIR}/src/ggml-opencl/ggml-opencl.cpp")
add_subdirectory("${workbench_ggml_SOURCE_DIR}" "${workbench_ggml_BINARY_DIR}")
if(TARGET ggml-opencl)
    target_compile_options(ggml-opencl PRIVATE -include "${CMAKE_CURRENT_SOURCE_DIR}/moss_opencl_dispatch.hpp")
endif()
# Debug APKs still need optimized matrix kernels for a meaningful phone test.
foreach(ggml_target ggml ggml-base ggml-cpu ggml-opencl)
    if(TARGET ${ggml_target})
        target_compile_options(${ggml_target} PRIVATE -O3)
    endif()
endforeach()
FetchContent_Declare(workbench_moss
    URL https://codeload.github.com/localai-org/moss-transcribe.cpp/tar.gz/190a569c13b4b247450f2fb3b2a431244e84833e
    URL_HASH SHA256=bf10df98f16a0755ce7c21b8ab8394ad0a0ae4aa101e55db021dc4f3d528de8a)
FetchContent_GetProperties(workbench_moss)
if(NOT workbench_moss_POPULATED)
    FetchContent_Populate(workbench_moss)
endif()
file(GLOB MOSS_SOURCES "${workbench_moss_SOURCE_DIR}/src/*.cpp")
list(REMOVE_ITEM MOSS_SOURCES "${workbench_moss_SOURCE_DIR}/src/cli.cpp")
list(REMOVE_ITEM MOSS_SOURCES "${workbench_moss_SOURCE_DIR}/src/backend.cpp"
    "${workbench_moss_SOURCE_DIR}/src/generate.cpp"
    "${workbench_moss_SOURCE_DIR}/src/model_loader.cpp"
    "${workbench_moss_SOURCE_DIR}/src/transcribe.cpp")
file(READ "${workbench_moss_SOURCE_DIR}/src/generate.cpp" MOSS_GENERATE)
string(REPLACE "if (!ggml_backend_supports_op(backend(), rows)) {"
    "if (!ggml_backend_supports_op(backend(), rows)) { if (!ggml_backend_is_cpu(backend())) throw std::runtime_error(\"GPU embedding fallback refused\");"
    MOSS_GENERATE "${MOSS_GENERATE}")
string(FIND "${MOSS_GENERATE}" "int t = argmax_first(logits);" english_argmax_anchor)
if(english_argmax_anchor EQUAL -1)
    message(FATAL_ERROR "Pinned MOSS generation anchor changed")
endif()
string(REPLACE "int t = argmax_first(logits);" "int t = wb::english_argmax(logits);"
    MOSS_GENERATE "${MOSS_GENERATE}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/moss_generate.cpp"
    "#include \"moss_english.hpp\"\n#include <stdexcept>\n#include \"ggml-cpu.h\"\n${MOSS_GENERATE}")
wb_patch_moss_loader("${workbench_moss_SOURCE_DIR}/src/model_loader.cpp"
    "${CMAKE_CURRENT_BINARY_DIR}/moss_model_loader.cpp")
file(READ "${workbench_moss_SOURCE_DIR}/src/transcribe.cpp" MOSS_TRANSCRIBE)
string(FIND "${MOSS_TRANSCRIBE}" "build_input_ids(tok, c, c.default_prompt, n_tokens);" english_prompt_anchor)
string(FIND "${MOSS_TRANSCRIBE}" "    std::vector<int32_t> input_ids =" english_scope_anchor)
if(english_prompt_anchor EQUAL -1 OR english_scope_anchor EQUAL -1)
    message(FATAL_ERROR "Pinned MOSS transcription anchors changed")
endif()
string(REPLACE "c.default_prompt, n_tokens" "wb::english_prompt(c.default_prompt), n_tokens"
    MOSS_TRANSCRIBE "${MOSS_TRANSCRIBE}")
string(REPLACE "    std::vector<int32_t> input_ids ="
    "    wb::EnglishDecoderScope english(tok, c.eos_token_id);\n    std::vector<int32_t> input_ids ="
    MOSS_TRANSCRIBE "${MOSS_TRANSCRIBE}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/moss_transcribe.cpp"
    "#include \"moss_english.hpp\"\n${MOSS_TRANSCRIBE}")
add_library(workbench_moss SHARED workbench_moss.cpp moss_backend.cpp moss_english.cpp
    "${CMAKE_CURRENT_BINARY_DIR}/moss_transcribe.cpp"
    "${CMAKE_CURRENT_BINARY_DIR}/moss_generate.cpp"
    "${CMAKE_CURRENT_BINARY_DIR}/moss_model_loader.cpp"
    ${MOSS_SOURCES})
target_include_directories(workbench_moss PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${workbench_moss_SOURCE_DIR}/include" "${workbench_moss_SOURCE_DIR}/src"
    "${workbench_moss_SOURCE_DIR}/third_party")
target_compile_options(workbench_moss PRIVATE -O3)
if(TARGET ggml-opencl)
    target_compile_definitions(workbench_moss PRIVATE WB_MOSS_OPENCL=1)
endif()
target_link_libraries(workbench_moss PRIVATE ggml "${log_library}")

option(WORKBENCH_MOSS_BUILD_PROBE "Build the device qualification probe" OFF)
if(WORKBENCH_MOSS_BUILD_PROBE)
    add_executable(workbench_moss_probe moss_probe.cpp)
    target_include_directories(workbench_moss_probe PRIVATE "${workbench_moss_SOURCE_DIR}/src")
    target_link_libraries(workbench_moss_probe PRIVATE workbench_moss ggml)
endif()
