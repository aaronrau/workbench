# Gemma transcript correction

## Runtime boundary

Gemma is a post-STT text corrector. Audio capture, LC3 decode, VAD, WAV
persistence, and Parakeet transcription remain independent:

```text
Main Android/Flutter process
  G2 BLE → journal → LC3 decode → VAD isolate → WAV
  WAV → Parakeet STT isolate → <segment>.raw.txt
                              ↓ durable pending-corrections.json

Dedicated :gemma Android process
  one serial worker → one LiteRT-LM Engine → one Conversation per segment
                    → <segment>.corrected.txt
```

The native engine is pinned to LiteRT-LM 0.14.0 with `Backend.GPU()`. A GPU
initialization or inference failure returns to the durable retry queue; CPU
fallback is not configured. Killing or exhausting the correction process must
not interrupt BLE, capture, VAD, STT, or the original transcript.

The Flutter bridge binds one `:gemma` service with Android's important-service
flag. That service owns one single-thread worker and one engine; it never starts
parallel engines to catch up. If Android kills the service for memory pressure,
`service_disconnected`, `service_send_failed`, `service_unavailable`, and
`memory_pressure` outcomes keep the live job in the same durable queue. Retry
delays are capped at 30 seconds and do not consume the three-attempt ceiling.
The replacement service processes queued jobs serially after rebinding.
Non-transient invalid output or inference failures still stop after three
attempts; the raw transcript remains durable and an active G2 detail changes
from `Sending:` to `Saved:` instead of remaining indefinitely in progress.
The optional conversation-analysis worker yields its independent native model
allocations while a live correction is pending, then resumes its durable WAV
queue afterward.

When correction is enabled and the verified model is installed, startup
prepares the engine asynchronously before the first transcript arrives. The
engine remains warm after each short-lived conversation instead of being
released on an inactivity timer. Android or Flutter memory-pressure handling,
an explicit release, a model reload, service shutdown, or process death may
still release it. The next live correction safely reloads the engine if that
happens.

After the raw transcript and correction ledger are durable, ready work enters
the serial correction pump immediately in the same Dart event turn. A
zero-duration timer is not the handoff boundary. Timers are reserved for real
retry backoff, and a pump request that arrives while another job is finishing
is latched and serviced before the supervisor can return idle. This prevents a
ready live job from remaining queued until unrelated later activity wakes the
process.

## Storage contract

App-private speech storage contains:

```text
<segment>.wav
<segment>.raw.txt
<segment>.corrected.txt
<segment>.transcript.json
<segment>.correction-skipped.json
<conversation>.continuous.txt
pending-transcriptions.json
pending-corrections.json
```

App-private user-visible files are written through a `.part` file followed by
an atomic rename. The raw transcript exists before correction starts. The
private metadata records stage timings and providers but does not duplicate
transcript text. When a shared folder is selected, final WAV and transcript
files plus `workbench-correction-prompt.txt` are stored there through Android's
document provider. The prompt file is excluded from the Messages list.
Legacy `<segment>.txt` files remain readable as original-only transcripts.

Correction is attention-gated before it enters the durable Gemma queue. A live
raw chunk is eligible when it begins with the complete word `hey`, matched
case-insensitively. A complete manual transcript submitted by the second tap of
an explicitly selected agent Listen Mode session is also eligible in the live
process. Its individual VAD/STT chunks remain collection-only. An unselected chunk without the leading
word is saved normally and receives a durable `no_wake_word` skip record;
startup recovery therefore cannot turn ambient speech or a mid-sentence mention
into a later correction job. During uninterrupted speech, STT
prefers the next short inter-word audio gap or VAD pause after 15 seconds and
uses a 17-second safety cap with one second of leading overlap in the
continuation WAV. The continuous file and
live correction/route input remove only an exact repeated boundary-word
sequence; every original per-chunk raw file remains independently durable.

Listen Mode explicitly activated from an agent's retained-message detail page
is routing intent, not acoustic wake evidence. Its first tap snapshots the
agent; VAD-separated STT results accumulate visibly without entering Gemma.
That is the Preview Correction Off behavior: the second tap waits for the final
VAD flush and queued STT, then places the complete durable transcript in the
live Gemma queue even without leading `Hey` and routes only its corrected result
to that still-configured agent. With Preview Correction On, each completed STT
append queues a serialized, transient correction of the newest aggregate. A
new append during inference marks the displayed preview stale and schedules one
new aggregate correction. Send waits for the current preview and persists its
text and timing metadata without a second Gemma request. If automatic preview
correction fails, Send does not retry it; the raw transcript is retained and is
not routed. Merely highlighting an agent row or opening its detail retains the
ordinary wake-word path. The final raw transcript remains independently
durable; transient preview artifacts are kept outside durable transcript
history and removed after each attempt.
Restored jobs never route, and correction failure preserves the raw fallback.
Memo and Dismiss never provide this override.

## Configuration

The source-controlled `config.example.json` is a generic schema example.
At runtime, the complete validated configuration is stored in
`workbench/config.json` inside app-private support storage. It is ignored by
Git. If the user selects a shared File storage folder, Settings saves only the
editable instruction text to `workbench-correction-prompt.txt` in that folder
and mirrors it into the private configuration. Model, backend, timeout, and
schema constraints remain app-private.

The app-owned initial prompt includes the guarded engineering vocabulary and
routing corrections. An acoustic agent variant such as `flex` or `fox` may
become `Flux` only after a leading `Hey`; a bare variant is never agent
activation evidence. An untouched prompt from the previous release migrates
to this default in both storage locations. A user-edited prompt is never
replaced by that migration.

At startup and before each queued segment begins, the supervisor rereads the
private fallback and then the shared prompt when available. A valid save or
external shared-file edit therefore affects the next segment without
restarting the Flutter app, native service, or engine. A missing shared prompt
is recreated from the private fallback. An invalid or unreadable external edit
does not replace the last valid snapshot.
Shared prompt reads and writes have a five-second bound. A document-provider
read timeout records a validation error and immediately continues correction
with the private last-known-good prompt, so external storage cannot pin the
live correction FIFO. A timed-out shared save fails without replacing the
private fallback.

Validation requires:

- schema version 1;
- model `gemma-4-e4b-it`;
- backend `gpu`;
- timeout from 5,000 to 120,000 milliseconds;
- non-empty instructions no longer than 10,000 characters;
- no unsupported control characters.

The shared prompt may contain user vocabulary and is not source material. Do
not copy it into the repository or test fixtures.

The output guard rejects empty text, expansion beyond twice the original plus
256 characters, or removal of numeric values, paths, or command-line flags.
Rejected output is never exported as corrected text; the original remains
available and the job retries with bounded backoff.

## Model installation

The exact Gemma model is versioned as four Git LFS chunks under `models/llm/`.
`tool/install_android_workbench.sh` builds and installs the APK, then streams
the chunks into app-private storage with Android `run-as`. This keeps the
Android installation reproducible and offline after the LFS checkout without
requiring phone root or retaining a second temporary model copy.

Before copying, the installer verifies each LFS chunk and their combined
3,659,530,240-byte model. It then verifies the reconstructed file on the phone
before atomically creating its `.verified` marker.

## Timing markers

STT completion logs `audio_ms`, `decode_ms`, and `total_ms`. Correction logs:

```text
[WorkBench][Correction] state=completed
  segment=<id>
  model=gemma-4-e4b-it
  provider=<provider>
  queue_ms=<n>
  engine_load_ms=<n>
  inference_ms=<n>
  correction_ms=<n>
  stt_decode_ms=<n>
  stt_total_ms=<n>
  pipeline_total_ms=<n>
  ttft_ms=<n>
  prefill_tps=<n>
  decode_tps=<n>
```

Do not put transcript text, device identifiers, model paths, or private
configuration into these markers.

## Continuous-run acceptance

A physical acceptance run lasts at least 15 minutes and keeps G2 audio
streaming while repeatedly producing speech turns. Preserve every trial,
including failures.

Sample the main and `:gemma` processes at the beginning, after warm-up, and
once per minute:

- PSS, RSS, and swap;
- Java and native heap;
- process restarts and low-memory kills;
- battery/thermal status;
- correction queue depth;
- STT and correction stage timings.

Acceptance requires:

- no capture failure, unexpected disconnect, or lost raw transcript;
- one Gemma engine and no live conversation between requests;
- the main process survives forced termination of `:gemma`;
- correction resumes from the ledger after service recovery;
- queue depth returns to zero after each burst;
- memory remains bounded after warm-up rather than increasing per turn;
- Settings changes affect the next transcript;
- original and corrected files remain separate and appear in that order in
  the Messages tab.

GPU qualification is a separate gate. `Backend.GPU()`, successful model load,
and faster timing are not sufficient by themselves. The packaged
LiteRT-LM 0.14.0 runtime and verified Gemma model passed that gate on a
representative RedMagic phone: Android attributed about 3.08 GB of GPU memory
to the isolated `:gemma` process after successful inference, a forced
low-memory engine release reduced it to about 13 MB without killing the
process, and the next successful correction restored about 3.03 GB. CPU
fallback remains disabled, so runtime status and transcript metadata report
`gpu`.

### Representative continuous result

The qualifying RedMagic run lasted 902.5 seconds and submitted 20 consecutive
physical turns without restarting either app process:

- 20/20 Gemma jobs completed and the durable queue returned to zero;
- zero unexpected disconnects, capture failures, transcription restarts,
  correction failures, or correction-service disconnects;
- warm Gemma inference averaged 1,098 ms (832–1,216 ms), and the complete
  STT-plus-correction pipeline averaged 2,809 ms;
- main-process RSS started at 1,875,260 KB, peaked at 1,900,920 KB, and ended
  at 1,889,796 KB;
- Gemma-process RSS started at 1,059,608 KB and ended at its observed maximum
  of 1,073,448 KB;
- battery temperature moved from 33°C to 34°C and swap fell from 89 KB to
  39 KB.

The acoustic scorer passed 15/20 turns. All five failures were transcript-WER
failures; every transport, activity, VAD, capture, and recovery check still
passed. Preserve that 75% physical accuracy result separately from the 100%
correction-completion result.
