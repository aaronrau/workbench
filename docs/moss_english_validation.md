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

## Build 180: smaller GPU token table

Build 180 retains the pinned model files, English policy, encoder, and single
serial MOSS inference path. Adapter `strict-provider-f16-1` expands the tied
token embedding/output table to F16 instead of F32 on OpenCL. Conversion uses
bounded blocks rather than allocating a complete F32 intermediate. The CPU
path keeps its original quantized table. Half rounding changes arithmetic, so
this is a separately qualified native revision, not a claim of bitwise parity.
The native service reports the adapter revision and Dart verifies it before
accepting output; metadata and held-job fingerprints also include the revision.

The exact arm64 library extracted from APK 180 has SHA-256
`36aebb06f5bf15e10a1c6e494ed73e78f7bd9144163d99154f86a1d2cd3c96a8`.
The device family remains RedMagic / Adreno 840, Android 16 / API 36. Upstream
runtime and ggml revisions and both model hashes remain those documented above
and in the linked qualification reports. This does not qualify other phones.

### Matched Q5_K timing

Each library decoded byte-identical saved inputs with four preprocessing
threads, one serial OpenCL worker, one warm-up, and three timed repetitions.
The normal app was stopped with input inactive to avoid a competing inference
worker. Both Q5 groups began with the current GPU temperature below 39 °C;
Android thermal status remained zero. Times exclude model loading and queue
waits. SHA-256 manifests, original audio, all outputs, temperature snapshots,
memory samples, and process-exit evidence remain private outside the repository.

| Audio | Build 179 | Build 180 | Decode-time reduction |
| --- | ---: | ---: | ---: |
| 4.4 s cropped G2 capture | 5.940 s | 5.568 s | 6.3% |
| 8.9 s archived G2 capture | 6.512 s | 5.968 s | 8.4% |
| 11.0 s public reference | 8.080 s | 7.335 s | 9.2% |
| 37.7 s synthetic mixed input | 23.756 s | 21.585 s | 9.1% |

All twelve Q5 outputs retained the same normalized words as the baseline and
valid timestamp/speaker framing. Both versions scored 7.69% WER on the archived
8.9-second fixture and 0% on the public reference and synthetic long fixture;
all scored final tails were retained. The 4.4-second crop has no separate gold
reference and is checked for baseline word parity, not claimed as a zero-error
recognition result. The long fixture repeats the archived G2 recording and
appends the public reference: it is not a natural long conversation or a fresh
acoustic test. These small fixtures do not establish broad accuracy parity.

The packaged Q4_0 check also retained three repetitions per input, beginning
after the current GPU temperature returned below 39 °C. Its medians were
5.161, 5.601, 6.852, and 20.489 seconds respectively. WER remained 7.69% on
the archived fixture, 0% on the public reference, and 4.92% on the synthetic
long fixture, with every scored final tail retained. Q4 is still selectable,
but the installed selection remains Q5 to retain its better long-fixture result.

All 24 packaged-library decodes had valid framing, positive GPU node counts
and hardware-event timings, zero CPU graph nodes, and zero sampled process
swap. The strict adapter still refuses unsupported GPU operations instead of
falling back. No probe process died. Peak Q4 PSS/RSS were 473,304/483,816 KiB.
Both models use the same registered OpenCL backend; VAD remains separately on
CPU. Flutter analysis is clean and all 466 tests pass, including refusal of an
unverified native adapter. The physical-loop scorer tests also pass (24 plus
13 tests), but no fresh acoustic G2 replay or sustained memory soak is claimed.
After installation, Android reported version 1.0.0/build 180. The app's own
Q5_K/OpenCL service reached ready and completed a saved-queue decode with
positive GPU work and zero CPU nodes; exactly one MOSS process owned the model.
This verified native inference, not successful Flutter transcript delivery:
the later build-183 investigation found the Android bridge omitted
`nativeAdapter`, causing Dart to reject these otherwise completed replies.
Build 183 forwards that field and invalidates the old held-job policy so saved
WAVs retry locally. The native timing and provider measurements above are
unchanged; they must not be cited as end-to-end app acceptance evidence.
Build 183 passes Flutter analysis and 470 tests, including service-to-bridge
field coverage and local-only recovery of recordings held by the old bridge.
On the phone, a 4.9-second saved WAV completed in 5.744 seconds and produced
both the atomic primary transcript and speaker-turn metadata. The saved
metadata identifies build 183, the expected adapter, 27,414 GPU nodes, zero
CPU nodes, and positive hardware timing events. This is saved-WAV recovery
evidence, not a new acoustic replay or an accuracy measurement.

Build 185 also prioritizes the newest restored capture timestamps across both
current and legacy MOSS filenames; live jobs retain dispatch priority. All 471
tests and Flutter analysis pass. Two short phone-microphone WAVs held by the
old bridge recovered through the installed app: 8.2 seconds of audio decoded
in 7.217 seconds, and 7.5 seconds decoded in 7.923 seconds. Both produced
annotation-free primary files and saved conversation files from the same
MOSS inference. Their original WAV hashes were unchanged. Saved metadata
identifies Q5_K/OpenCL, the expected adapter, positive hardware timing events,
and zero CPU nodes. Expected words were not supplied, so these checks verify
recovery and persistence, not word accuracy. No new G2 acoustic replay is
claimed.

Build 188 adds an Events summary for active transcription/saving, elapsed time,
queued and held counts, completion counts, retries, and the last failure.
Elapsed time is not an inference completion percentage. Continuous audio,
storage, and protocol diagnostics remain in logcat and are excluded from the
Events history. Phone microphone metering refreshes independently of logging.
Flutter analysis and all 473 app tests pass; the physical runner suites pass
25 and 13 tests. The Events layout was inspected on the phone and covered at
a 390-by-844 viewport.

Two attempted physical trials stopped before computer-speaker playback. The
first failed to resume fresh audio after reconnect; the second could not find
the glasses during initial connection. Both trial directories and preflight
reports were retained privately. The runner now waits for an enabled visible
Connect devices control after VAD flush, since disconnect cleanup can still
own the button at that point. No successful new acoustic replay through either
input is claimed for this change; both speaker tests remain pending hardware
availability and a passing reconnect preflight.

Sampled Q5 peak PSS fell from 813,048 KiB to 508,690 KiB (about 794 to 497 MiB),
and peak RSS from 822,700 KiB to 518,984 KiB, with zero sampled process swap.
These process measurements do not account for all vendor GPU allocations or
replace a continuous-operation memory test. Short clips still decode slower
than real time because the 30-second encoder input remains unchanged. The
official [MOSS processor](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize/blob/0844c4adb24300bc7c6cd91e379bc790f939f2d6/processing_moss_transcribe_diarize.py)
uses that padded input format; this change preserves it.

### Retained exploratory results

The initial unchanged-runtime Q4 trial did not reproduce the historical speed
advantage: medians were 6.346, 6.949, 8.378, and 27.162 seconds on the same four
inputs. Its actual GPU starting temperature was higher than Q5's despite both
reporting Android thermal status zero, so these sequential groups are not a
controlled quantization ranking. Q4 again scored 4.92% WER on the synthetic
long input, versus Q5's 0%. The isolated F16 prototype then passed six Q5
decodes before the complete packaged-library check. All attempts are retained;
the installed selection stays Q5_K.
