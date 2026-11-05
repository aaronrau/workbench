// Explicit saved-WAV qualification only. Never print transcript text or paths.
#include "model_loader.hpp"
#include "transcribe.hpp"
#include "common.hpp"
#include "backend.hpp"
#include "ggml.h"
#include "ggml-cpu.h"
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <cstdint>
#include <string>
extern "C" void wb_moss_profile_reset();
extern "C" void wb_moss_profile_get(uint64_t*);
static void quiet(mt::mt_log_level, const char*, void*) {}
static void quiet_ggml(ggml_log_level, const char*, void*) {}
int main(int argc, char** argv) {
    // provider, model, model ID, private output prefix, then one or more WAVs.
    if (argc < 6) return 2;
    const std::string wanted = argv[1], model_id = argv[3];
    if ((wanted != "cpu" && wanted != "opencl") ||
        (model_id != "moss-0.9b-q4_0" && model_id != "moss-0.9b-q5_k")) return 2;
    setenv("MTD_DEVICE", argv[1], 1);
    setenv("MTD_THREADS", "4", 1);
    mt::set_log_callback(quiet, nullptr);
    ggml_log_set(quiet_ggml, nullptr);
    try {
        mt::ModelLoader model;
        const auto load_start = std::chrono::steady_clock::now();
        if (!model.load(argv[2])) return 3;
        model.promote_small_f16_to_f32();
        const std::string actual = ggml_backend_is_cpu(mt::backend()) ? "cpu" : "opencl";
        if (actual != wanted) return 6;
        const auto load_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-load_start).count();
        std::cerr << "[WorkBench][Transcription] state=ready model=" << model_id
                  << " provider=" << actual << " threads=4 load_ms=" << load_ms << std::endl;
        // Warm the identical first WAV once, then retain all three timed rounds.
        if (mt::transcribe_wav(model, argv[5], 1024).empty()) return 4;
        std::cerr << "stage=warmup_completed model=" << model_id << std::endl;
        for (int round = 0; round < 3; ++round) {
            for (int input = 5; input < argc; ++input) {
                wb_moss_profile_reset();
                const auto started = std::chrono::steady_clock::now();
                const auto text = mt::transcribe_wav(model, argv[input], 1024);
                const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-started).count();
                if (text.empty()) return 4;
                uint64_t p[5]; wb_moss_profile_get(p);
                if (actual == "opencl" && (p[1] == 0 || p[2] != 0 || p[3] == 0 || p[4] == 0)) return 6;
                const std::string output = std::string(argv[4]) + "-" + std::to_string(input-5) + "-" + std::to_string(round) + ".txt";
                std::ofstream file(output); file << text; file.close();
                if (!file) return 7;
                std::cout << "{\"model\":\"" << model_id << "\",\"provider\":\"" << actual
                          << "\",\"input\":" << input-5 << ",\"round\":" << round
                          << ",\"decode_ms\":" << ms << ",\"graphs\":" << p[0]
                          << ",\"gpu_nodes\":" << p[1] << ",\"cpu_nodes\":" << p[2]
                          << ",\"gpu_ns\":" << p[3] << ",\"gpu_queries\":" << p[4] << "}" << std::endl;
                std::cerr << "[WorkBench][Transcription] state=completed model=" << model_id
                          << " provider=" << actual << " input=" << input-5 << " round=" << round
                          << " decode_ms=" << ms << std::endl;
            }
        }
        return 0;
    } catch (const std::exception&) {
        std::cerr << "MOSS qualification failed" << std::endl;
        return 5;
    }
}
