# MOSS English transcription validation

Development build 174 adds `english-latin-v2` to the pinned MOSS/ggml runtime
qualified in [the GPU report](moss_gpu_qualification.md). The base application
revision is `b0390a5` plus these English-policy changes. The packaged arm64
library SHA-256 is
`325025a04f02e292369876f88a8bc46bbb4a7948e2144139e78d7ec8292a04e4`.
The target remains the representative RedMagic / Adreno 840 family on Android
16 / API 36. This qualification does not transfer to another runtime, model,
OS, or phone family.

The native PCM/WAV core retains the model's trained timestamp/speaker prompt
and adds explicit English instructions before and after it. This uses MOSS's
[custom transcription prompt support](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize/blob/main/examples/prompts.md).
Greedy selection masks writing systems outside Latin before selecting each
token. Accented Latin letters and common punctuation remain available. The
mask tracks partial UTF-8 characters across byte-BPE boundaries, refuses an
unfinished character at EOS, and excludes padded logits without vocabulary
entries. Cached vocabulary masks bound the extra host work; model graphs
continue to run on the selected provider.

The app requires the native English-policy version in each completion before
it saves the completed raw transcript or dispatches delivery. Private MOSS
metadata records `language: en` and the policy version. Original saved audio
and earlier transcripts remain unchanged.

## Device checks

Both selectable weights were independently rechecked against the exact shared
library extracted from the APK. Each model completed three timed repetitions
of an 11-second public reference and three of an unchanged, saved G2 recording
that had previously produced Chinese-script output. All 12 results:

- contained Latin-script text with valid timestamp/speaker framing;
- assigned positive model-node counts to OpenCL and zero nodes to CPU;
- recorded positive hardware kernel-event timings and query counts;
- completed without a probe-process death or sampled process swap.

All six public-reference decodes had zero normalized word errors. The private
recording has no independently supplied reference text, so no word-error or
speaker-identification accuracy score is claimed for it. This validates the
language restriction and preserves original files; it is not an acoustic G2
replay, a broad accuracy benchmark, or a continuous-operation memory test.
Raw outputs, hashes, profiles, timing, memory samples, and thermal snapshots
are retained as private evidence outside the repository.

An additional check exercised the exported C API used by Android against the
same recent clip and an older, unfinished 15-second queue entry. The recent
clip completed with positive OpenCL work and zero CPU nodes. The older entry
returned an empty transcription, also with zero CPU nodes; the app retained
its original WAV and reported the existing failed-job state. No reference
text is available for that entry, so an empty result is not evidence that the
recording contained no speech. The original failure and diagnostic evidence
are retained privately.

The first standalone probe could not open the vendor driver in its restricted
linker namespace and performed no inference. Its failure was retained; the
probe's vendor-library search path was then configured explicitly. A first
prompt candidate produced placeholder timestamps on all three Q4 public
reference trials, although its three private-clip trials and all six Q5 trials
were framed correctly. Those failures were retained. Keeping the trained
formatting instructions fixed that candidate's formatting regression; the
final policy passed all 12 repeated checks above.

Native policy checks cover non-Latin tokens outranking English, split accented
characters, split CJK continuation attempts, EOS, padded vocabulary entries,
invalid UTF-8, non-finite logits, and tie ordering. Flutter analysis is clean
and all 450 Flutter tests pass, including refusal of a completion that reports
another language or an unverified native language policy.
