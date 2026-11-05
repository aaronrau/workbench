// Strict single-provider adapter for the pinned MIT-licensed MOSS runtime.
// GPU graph operations may never fall back to CPU. Host audio preprocessing,
// tokenization, and argmax remain ordinary host work, not model-node fallback.
#include "backend.hpp"
#include "ggml-alloc.h"
#include "ggml-cpu.h"
#ifdef WB_MOSS_OPENCL
#include "ggml-opencl.h"
#endif
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <cstdio>

namespace {
ggml_backend_t selected = nullptr;
ggml_gallocr_t allocator = nullptr;
std::once_flag once;
std::atomic<uint64_t> gpu_nodes{0}, cpu_nodes{0}, gpu_ns{0}, queries{0}, graphs{0};
bool gpu = false;
void initialize() {
    const char* wanted = std::getenv("MTD_DEVICE");
    gpu = wanted && std::strcmp(wanted, "opencl") == 0;
    if (gpu) {
#ifdef WB_MOSS_OPENCL
        auto reg = ggml_backend_opencl_reg();
        if (ggml_backend_reg_dev_count(reg) == 0) throw std::runtime_error("OpenCL GPU unavailable");
        ggml_backend_register(reg);
        selected = ggml_backend_opencl_init();
        const auto type = selected ? ggml_backend_dev_type(ggml_backend_get_device(selected)) : GGML_BACKEND_DEVICE_TYPE_CPU;
        if (!selected || !ggml_backend_is_opencl(selected) ||
            (type != GGML_BACKEND_DEVICE_TYPE_GPU && type != GGML_BACKEND_DEVICE_TYPE_IGPU)) {
            throw std::runtime_error("Hardware OpenCL backend required");
        }
#else
        throw std::runtime_error("MOSS GPU requires arm64 Android");
#endif
    } else {
        selected = ggml_backend_cpu_init();
        if (selected) ggml_backend_cpu_set_n_threads(selected, 4);
    }
    if (!selected) throw std::runtime_error("Requested MOSS backend unavailable");
    allocator = ggml_gallocr_new(ggml_backend_get_default_buffer_type(selected));
}
bool compute(ggml_cgraph* graph, const std::function<void()>& inputs) {
    auto b = mt::backend();
    uint64_t nodes = 0;
    for (int i = 0; i < ggml_graph_n_nodes(graph); ++i) {
        auto node = ggml_graph_node(graph, i);
        if (node->op == GGML_OP_NONE || node->op == GGML_OP_RESHAPE || node->op == GGML_OP_VIEW ||
            node->op == GGML_OP_PERMUTE || node->op == GGML_OP_TRANSPOSE) continue;
        if (!ggml_backend_supports_op(b, node)) {
            // The error contains only an operator label, never tensor contents.
            throw std::runtime_error(std::string("Unsupported MOSS op: ") + ggml_op_name(node->op));
        }
        ++nodes;
    }
    if (!ggml_gallocr_alloc_graph(allocator, graph)) return false;
    if (std::getenv("WB_MOSS_TRACE")) std::fprintf(stderr, "graph=%llu nodes=%llu first_op=%s\n", static_cast<unsigned long long>(graphs.load()), static_cast<unsigned long long>(nodes), ggml_op_name(ggml_graph_node(graph, 0)->op));
    if (inputs) inputs();
    if (ggml_backend_graph_compute(b, graph) != GGML_STATUS_SUCCESS) return false;
    ggml_backend_synchronize(b);
    (gpu ? gpu_nodes : cpu_nodes).fetch_add(nodes);
    ++graphs;
    return true;
}

}

extern "C" void wb_moss_gpu_timing(uint64_t ns, uint64_t count) {
    gpu_ns += ns; queries += count;
}
extern "C" void wb_moss_profile_reset() {
    gpu_nodes = 0; cpu_nodes = 0; gpu_ns = 0; queries = 0; graphs = 0;
}
extern "C" void wb_moss_profile_get(uint64_t* values) {
    values[0] = graphs; values[1] = gpu_nodes; values[2] = cpu_nodes;
    values[3] = gpu_ns; values[4] = queries;
}
namespace mt {
ggml_backend_t backend() { std::call_once(once, initialize); return selected; }
const char* backend_name() { return ggml_backend_name(backend()); }
bool compute_graph(ggml_cgraph* graph) { return compute(graph, {}); }
bool compute_graph_with_inputs(ggml_cgraph* graph, const std::function<void()>& inputs) {
    return compute(graph, inputs);
}
ggml_backend_buffer_t allocate_ctx_tensors(ggml_context* ctx) {
    return ggml_backend_alloc_ctx_tensors(ctx, backend());
}
bool backend_supports_flash_attn() {
    return false;
}
bool read_tensor_f32(const ggml_tensor* t, std::vector<float>* out) {
    if (!t || !out || t->type != GGML_TYPE_F32) return false;
    out->resize(ggml_nelements(t));
    ggml_backend_tensor_get(t, out->data(), 0, out->size() * sizeof(float));
    return true;
}
bool read_tensor_i32(const ggml_tensor* t, std::vector<int32_t>* out) {
    if (!t || !out || t->type != GGML_TYPE_I32) return false;
    out->resize(ggml_nelements(t));
    ggml_backend_tensor_get(t, out->data(), 0, out->size() * sizeof(int32_t));
    return true;
}
}
