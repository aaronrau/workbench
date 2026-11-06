#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace mt { class Tokenizer; }
namespace wb {
inline constexpr char kEnglishPolicy[] = "english-latin-v2";
// Retain the GGUF's trained timestamp/speaker instructions. An explicit
// language prefix/suffix selects English without teaching placeholder text.
inline std::string english_prompt(const std::string& format_prompt) {
    return "The audio is in English. Transcribe the spoken English words.\n" +
        format_prompt +
        "\nOutput English only. Keep the timestamps and speaker IDs. Do not translate.";
}

// Latin letters, combining accents, and ordinary English punctuation. These
// ranges constrain script, not word choice; the prompt supplies the language.
inline constexpr uint32_t kEnglishRanges[][2] = {
    {9, 10}, {13, 13}, {0x20, 0x7e}, {0xa0, 0xa0}, {0xa3, 0xa3},
    {0xa9, 0xa9}, {0xae, 0xae}, {0xb0, 0xb0}, {0xb7, 0xb7},
    {0xc0, 0xd6}, {0xd8, 0xf6}, {0xf8, 0x24f}, {0x300, 0x36f},
    {0x1e00, 0x1eff}, {0x2010, 0x2015}, {0x2018, 0x201f},
    {0x2026, 0x2026}, {0x202f, 0x202f}, {0x2032, 0x2033},
    {0x20ac, 0x20ac}, {0x2122, 0x2122},
};

struct EnglishUtf8State {
    uint32_t point = 0, minimum = 0;
    unsigned remaining = 0;
    uint64_t key() const {
        return (uint64_t(point) << 32) | (uint64_t(minimum) << 8) | remaining;
    }
    bool can_finish() const {
        uint32_t low = std::max(minimum, point << (6 * remaining));
        uint32_t high = ((point + 1) << (6 * remaining)) - 1;
        for (const auto& range : kEnglishRanges) {
            if (low <= range[1] && high >= range[0]) return true;
        }
        return false;
    }
    bool append(const std::string& bytes) {
        for (unsigned char byte : bytes) {
            if (remaining) {
                if ((byte & 0xc0) != 0x80) return false;
                point = (point << 6) | (byte & 0x3f);
                --remaining;
            } else if (byte <= 0x7f) {
                point = byte; minimum = 0;
            } else if (byte >= 0xc2 && byte <= 0xdf) {
                point = byte & 0x1f; minimum = 0x80; remaining = 1;
            } else if (byte >= 0xe0 && byte <= 0xef) {
                point = byte & 0x0f; minimum = 0x800; remaining = 2;
            } else if (byte >= 0xf0 && byte <= 0xf4) {
                point = byte & 7; minimum = 0x10000; remaining = 3;
            } else {
                return false;
            }
            if (!can_finish()) return false;
            if (!remaining) { point = 0; minimum = 0; }
        }
        return true;
    }
};

// Decode-time masking supports byte-BPE pieces split inside UTF-8 characters.
// A leading byte is accepted only when an allowed completion is possible.
// Cached masks make the usual ASCII path one lookup per candidate token.
class EnglishTokenPolicy {
public:
    EnglishTokenPolicy(std::vector<std::string> decoded, int eos)
        : decoded_(std::move(decoded)), eos_(eos) {
        if (eos < 0 || size_t(eos) >= decoded_.size()) {
            throw std::runtime_error("Invalid English decoder EOS");
        }
    }
    void reset() { state_ = {}; }
    size_t size() const { return decoded_.size(); }
    int eos() const { return eos_; }
    int select(const std::vector<float>& logits) {
        if (logits.size() < decoded_.size()) {
            throw std::runtime_error("English decoder vocabulary mismatch");
        }
        auto found = masks_.find(state_.key());
        if (found == masks_.end()) {
            std::vector<uint8_t> mask(decoded_.size(), 0);
            for (size_t i = 0; i < decoded_.size(); ++i) {
                auto next = state_;
                mask[i] = int(i) == eos_ ? state_.remaining == 0 :
                    !decoded_[i].empty() && next.append(decoded_[i]);
            }
            found = masks_.emplace(state_.key(), std::move(mask)).first;
        }
        int best = -1;
        for (size_t i = 0; i < decoded_.size(); ++i) {
            if (found->second[i] && std::isfinite(logits[i]) &&
                (best < 0 || logits[i] > logits[best])) best = int(i);
        }
        if (best < 0) throw std::runtime_error("No English decoder candidate");
        if (best != eos_ && !state_.append(decoded_[best])) {
            throw std::runtime_error("Invalid English decoder state");
        }
        return best;
    }
private:
    std::vector<std::string> decoded_;
    int eos_;
    EnglishUtf8State state_;
    std::map<uint64_t, std::vector<uint8_t>> masks_;
};

class EnglishDecoderScope {
public:
    EnglishDecoderScope(const mt::Tokenizer& tokenizer, int eos);
    ~EnglishDecoderScope();
    EnglishDecoderScope(const EnglishDecoderScope&) = delete;
    EnglishDecoderScope& operator=(const EnglishDecoderScope&) = delete;
};
int english_argmax(const std::vector<float>& logits);
void reset_english_decoder_cache();
}  // namespace wb
