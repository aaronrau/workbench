// Native regression for clipped speaker segments. All generated samples are
// synthetic and stay in memory; this test never records, plays, or prints audio.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <unordered_map>
#include <utility>
#include <vector>

#include "Eigen/Dense"
#include "sherpa-onnx/csrc/fast-clustering.h"
#include "sherpa-onnx/csrc/macros.h"
#include "sherpa-onnx/csrc/math.h"
#include "sherpa-onnx/csrc/offline-speaker-diarization-impl.h"
#include "sherpa-onnx/csrc/offline-speaker-segmentation-pyannote-model.h"
#include "sherpa-onnx/csrc/speaker-embedding-extractor.h"

// Access the real embedding loop so the regression does not depend on a
// segmentation model happening to emit a particular synthetic speaker label.
// All dependency headers are included first; this changes only test access.
#define private public
#include "sherpa-onnx/csrc/offline-speaker-diarization-pyannote-impl.h"
#undef private

namespace {
bool Check(bool condition, const char *message) {
  if (!condition) std::fprintf(stderr, "FAIL: %s\n", message);
  return condition;
}
}  // namespace

int main(int argc, char **argv) {
  if (argc != 3) {
    std::fprintf(stderr, "Usage: diarization-short-segments-test SEGMENTATION_MODEL EMBEDDING_MODEL\n");
    return 2;
  }
  sherpa_onnx::OfflineSpeakerDiarizationConfig config;
  config.segmentation.pyannote.model = argv[1];
  config.segmentation.provider = "cpu";
  config.segmentation.num_threads = 1;
  config.embedding.model = argv[2];
  config.embedding.provider = "cpu";
  config.embedding.num_threads = 1;
  config.min_duration_on = 0.25;
  config.min_duration_off = 0.35;
  sherpa_onnx::OfflineSpeakerDiarizationPyannoteImpl diarizer(config);

  constexpr int sample_rate = 16000;
  std::vector<float> samples(4 * sample_rate);
  for (size_t i = 0; i < samples.size(); ++i) {
    const double t = static_cast<double>(i) / sample_rate;
    samples[i] = 0.15 * std::sin(2 * 3.141592653589793 * 220 * t) +
                 0.05 * std::sin(2 * 3.141592653589793 * 731 * t);
  }
  const int n = samples.size();
  using Range = sherpa_onnx::Int32Pair;
  const std::vector<std::vector<Range>> mixed = {
      {{0, 50}}, {{0, 3 * sample_rate}}, {{n - 20, n + sample_rate}},
      {{sample_rate, n}}};
  std::vector<int32_t> valid;
  int callbacks = 0;
  bool progress_ok = true;
  auto progress = [&](int processed, int total, void *) -> int32_t {
    ++callbacks;
    progress_ok &= processed == callbacks && total == 4;
    return 0;
  };
  const auto embeddings = diarizer.ComputeEmbeddings(
      samples.data(), n, mixed, &valid, progress, nullptr);
  if (!Check(valid == std::vector<int32_t>({1, 3}), "valid speaker indexes") ||
      !Check(embeddings.rows() == 2 && embeddings.allFinite(), "retained embeddings") ||
      !Check(callbacks == 4 && progress_ok, "progress includes skipped speakers")) {
    return 1;
  }

  valid.clear();
  callbacks = 0;
  const std::vector<std::vector<Range>> short_only = {
      {{0, 50}}, {{n - 20, n + sample_rate}}};
  auto short_progress = [&](int processed, int total, void *) -> int32_t {
    ++callbacks;
    progress_ok &= processed == callbacks && total == 2;
    return 0;
  };
  const auto empty = diarizer.ComputeEmbeddings(
      samples.data(), n, short_only, &valid, short_progress, nullptr);
  if (!Check(empty.rows() == 0 && valid.empty(), "all-short embeddings") ||
      !Check(callbacks == 2 && progress_ok, "all-short progress")) {
    return 1;
  }

  // A later valid call must still work after the all-short input.
  valid.clear();
  const auto recovered = diarizer.ComputeEmbeddings(
      samples.data(), n, {{{0, n}}}, &valid, nullptr, nullptr);
  if (!Check(recovered.rows() == 1 && recovered.allFinite() &&
             valid == std::vector<int32_t>({0}), "recovery after short input")) {
    return 1;
  }
  std::puts("PASS: short, clipped, mixed, all-short, progress, and recovery");
  return 0;
}
