#include "moss_english.hpp"
#include "tokenizer.hpp"
#include <memory>

namespace wb {
namespace {
thread_local std::unique_ptr<EnglishTokenPolicy> cached;
thread_local EnglishTokenPolicy* active = nullptr;
}
EnglishDecoderScope::EnglishDecoderScope(const mt::Tokenizer& tokenizer, int eos) {
    if (active) throw std::runtime_error("Concurrent English decoding refused");
    if (!cached) {
        std::vector<std::string> decoded;
        decoded.reserve(tokenizer.vocab_size());
        for (size_t i = 0; i < tokenizer.vocab_size(); ++i) {
            decoded.push_back(tokenizer.decode({int32_t(i)}));
        }
        cached = std::make_unique<EnglishTokenPolicy>(std::move(decoded), eos);
    }
    if (cached->size() != tokenizer.vocab_size() || cached->eos() != eos) {
        throw std::runtime_error("English decoder cache mismatch");
    }
    cached->reset();
    active = cached.get();
}
EnglishDecoderScope::~EnglishDecoderScope() { active = nullptr; }
int english_argmax(const std::vector<float>& logits) {
    if (!active) throw std::runtime_error("English decoder scope required");
    return active->select(logits);
}
void reset_english_decoder_cache() {
    if (active) throw std::runtime_error("English decoder is active");
    cached.reset();
}
}  // namespace wb
