#include "moss_english.hpp"
#include <cassert>
#include <iostream>

static void valid(const std::string& text) {
    wb::EnglishUtf8State state;
    assert(state.append(text) && state.remaining == 0);
}
int main() {
    valid("[0.00][S01]English speech, 42 words![2.50]");
    valid(u8"The café’s naïve façade — £5 and €10…");
    for (const auto& text : {u8"中文", u8"日本語", u8"한국어", u8"Пример", u8"مثال"}) {
        wb::EnglishUtf8State state;
        assert(!state.append(text));
    }
    for (const std::string text : {std::string("\xc0\xaf"), std::string("\xed\xa0\x80"), std::string("\xf4\x90\x80\x80")}) {
        wb::EnglishUtf8State state;
        assert(!state.append(text));
    }
    // A Chinese token can have a higher score but must never beat English.
    wb::EnglishTokenPolicy basic({"Hello", u8"你好", "Second", ""}, 3);
    assert(basic.select({1, 100, 1, -1}) == 0);
    assert(basic.select({1, 100, 1, -1, 1000}) == 0); // padded logits have no token
    assert(basic.select({-1, 100, -2, 0}) == 3);
    // Byte-BPE can split inside an accented name. EOS and ASCII cannot cut it.
    wb::EnglishTokenPolicy accent({"\xc3", "\xa9", "name", ""}, 3);
    assert(accent.select({10, 0, 0, 0}) == 0);
    assert(accent.select({0, 1, 100, 200}) == 1);
    assert(accent.select({0, 0, 0, 1}) == 3);
    accent.reset();
    assert(accent.select({-1, 100, 0, -1}) == 2);
    // A shared UTF-8 prefix must not allow CJK continuation bytes through.
    wb::EnglishTokenPolicy shared({"\xe2", "\xba\x80", "\x80\x99", "ok", ""}, 4);
    assert(shared.select({10, 0, 0, 0, 0}) == 0);
    assert(shared.select({0, 100, 1, 100, 200}) == 2);
    assert(shared.select({-1, -1, -1, 0, 1}) == 4);
    bool refused = false;
    try { basic.select({1}); } catch (const std::runtime_error&) { refused = true; }
    assert(refused);
    refused = false;
    try { basic.select(std::vector<float>(4, std::numeric_limits<float>::quiet_NaN())); }
    catch (const std::runtime_error&) { refused = true; }
    assert(refused);
    std::cout << "English policy checks passed\n";
}
