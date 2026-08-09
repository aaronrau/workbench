# Transcription turn test plan

## Purpose

Validate that continuous G2 audio becomes reliable conversational turns:

```text
speech → 500 ms detector silence → clear prior pre-roll
→ 1.50 second default endpoint tail → atomic final WAV
→ persistent FIFO STT worker (one job at a time)
→ append every result to the logical turn
→ final chunk only: one full-transcript action
```

All acoustic stimuli use Kokoro speaker `af_maple` (`sid=0`, American English)
through the computer speaker. Phone/app playback is forbidden and rejected by
both physical runners.

## Test validity architecture

```text
Layer 1: physical path
Kokoro → speaker → G2 → BLE → durable WAV → VAD/queue
                                      └── preserve immutable source WAV

Layer 2: recognizer comparison
same G2 WAV + same phone/runtime ─┬─ Tiny Whisper
                                  ├─ Parakeet 110M
                                  └─ Parakeet 0.6B
```

These layers answer different questions. Physical replay proves capture, VAD,
and safety. Only byte-for-byte matched WAV input can compare recognizers.
Separate speaker replays must not be ranked against one another because room
noise, level, placement, packet loss, and VAD timing change the input.

Every physical case emits `playback_start` and `playback_end` into Android
logcat. The quiet baseline is the last available audio summaries before
`playback_start`; audio and transcripts after it are scored. Missing boundaries
fail the case. Playback uses a fixed 90% computer volume, one second of
zero-PCM leading silence, and 500 ms of zero-PCM trailing silence; original
volume is restored on every exit path.

Before a single run or suite starts playback, its runner foregrounds Work
Bench, connects first if needed, taps **Disconnect**, waits for
**Connect devices**, taps **Connect devices**, and waits for **Disconnect** and
fresh G2 frame summaries. The runner preserves the preflight log and JSON
result and fails before speaker playback if the button cycle or audio readiness
does not complete. When startup leaves the button disabled, it waits for the
current pipeline-ready marker and retries the same visible control; fresh audio
arriving during that wait proceeds immediately. Stale connection markers are
never accepted.

Every trial uses a fresh output directory. Its report records the clean
stimulus and actual playback WAV hashes and formats. Preserve all passing and
failing reports. A passing retry is additional evidence, not a replacement for
an earlier failure.

## Run

With the phone unlocked and both G2 lenses available to Work Bench:

```bash
python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_turn_suite.py \
  --output-dir /tmp/workbench-kokoro-turn-suite \
  --computer-volume 0.90
```

The runner writes a stimulus, device log, and JSON report for every case, plus
one `suite-report.json`. It restores the computer speaker's original volume in
a `finally` block.

Run the standard expanded profiles with:

```bash
python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_turn_suite.py \
  --profile duration \
  --profile boundary \
  --output-dir /tmp/workbench-kokoro-expanded \
  --computer-volume 0.90
```

Repeat only the uncertain boundary cases without rerunning long stimuli:

```bash
python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_turn_suite.py \
  --case duration_clip_600ms_characterize \
  --case duration_clip_650ms_characterize \
  --case duration_clip_700ms_characterize \
  --case gap_1900ms_characterize \
  --case gap_2000ms_characterize \
  --case gap_2050ms_characterize \
  --repeat 3 \
  --output-dir /tmp/workbench-kokoro-boundary-repeats \
  --computer-volume 0.90
```

Run the runner scoring regression before a physical suite:

```bash
python3 .agents/skills/kokoro-g2-transcription-loop/scripts/test_kokoro_g2_loop.py &&
python3 .agents/skills/kokoro-g2-transcription-loop/scripts/test_kokoro_turn_suite.py
```

## Test sequences

| Case | Stimulus | Expected VAD/STT behavior |
| --- | --- | --- |
| Long continuous | One long phrase without an intentional pause | One segment, one queue entry, one final transcript |
| Short continuation | Three short clauses separated by 400 ms | One segment; short natural pauses do not end the turn |
| Separated questions | Three questions separated by 2.2 seconds | Three segments and three ordered transcripts |
| Queue overlap | Short turns separated by 2.2 seconds | Each turn closes independently while the prior STT job may still be processing |

The phrases use distinct nouns and colors so a transcript from one turn leaking
into the next is detectable.

## Comprehensive duration and timing matrix

Run the matrix in four phases. Preserve every stimulus, device log, and JSON
report so results can be compared without replaying an ambiguous phrase.

### Matched-input recognizer cases

Capture these once through G2, then decode immutable copies with every STT
candidate. Each decode uses the same phone, app revision, provider, thread
count, and thermal starting band.

| ID | Saved G2 WAV | Required assertion |
| --- | --- | --- |
| M1 | 3–5 seconds | WER, decode time, and complete phrase |
| M2 | 10–20 seconds | WER, decode time, complete phrase, stable memory |
| M3 | More than 30 seconds | WER plus a unique phrase in the final 5 seconds |

For each source, preserve SHA-256, bytes, sample rate, duration, and expected
text. For each model, require matching ready/completed model IDs, repeat decode
timing three times, and report median decode time, word count, PSS/RSS/swap,
thermal state, and low-memory/process-kill events. VAD turn counts remain in
the physical test report and are not model metrics.

### Phase A: minimum speech duration

These cases characterize the lower VAD boundary. Sub-threshold clips validate
noise rejection; qualifying clips validate that short commands are not lost.
Each boundary probe is repeated three times.

| ID | Audible speech target | Repetitions | Expected result |
| --- | ---: | ---: | --- |
| A1 | 100 ms | 3 | No completed turn |
| A2 | 200 ms | 3 | No completed turn |
| A3 | 300 ms | 3 | Boundary characterization; record detection ratio |
| A4 | 500 ms | 3 | Boundary characterization; record detection ratio |
| A5 | 600, 650, 700, 800, and 900 ms | 3 each | Locate the physical detection transition |
| A6 | One natural short word | 3 | Characterize full-word detection ratio |
| A7 | One 3–5 word phrase | 3 | Three completed turns and scored transcripts |

The 300–900 ms cases characterize the physical path around Silero's configured
250 ms minimum speech duration. The setting is not assumed to be the acoustic
threshold after speaker, room, microphone, codec, and model-window effects.
These cases must never crash, disconnect, or leave an unfinished segment, but
their detection ratio is recorded rather than forced to pass as speech or
silence.

### Phase B: continuous-turn duration

No intentional gap may reach the endpoint boundary in these stimuli.

| ID | Approximate duration | Expected result |
| --- | ---: | --- |
| B1 | 1 second | One turn |
| B2 | 5 seconds | One turn |
| B3 | 15 seconds | One logical turn; no forced mid-word close at the soft target |
| B4 | 30 seconds | One logical turn; at least two ordered STT chunks append to one continuous transcript |
| B5 | 60 seconds | One logical turn; bounded chunks continue without a false silence endpoint |
| B6 | 2 minutes | One logical turn; extended bounded-queue check |
| B7 | 5 minutes | One logical turn; soak check with continuous durable appends |
| B8 | 15 minutes | One logical turn; soft-pause or overlapped hard rollovers remain bounded |

For B1–B5, transcript WER remains a hard assertion. B6–B8 additionally measure
WAV finalization time, peak memory, storage growth, transcription latency,
ordered append integrity, and whether audio/ring processing remains responsive.
Every case longer than 15 seconds validates that duration rollovers do not emit
`speech_ended` until a real endpoint and do not create an unbounded STT job.
The scorer accepts at most 19.5 seconds of WAV audio (including the initial
two-second pre-roll or a continuation's one-second overlap), requires
`durationPause` and `durationWordBoundary` continuations to report zero overlap, requires
`durationHardLimit` continuations to report exactly 1,000 ms, deduplicates the
exact recognized boundary sequence for WER, and still fails on missing words.

### Phase C: silence-gap boundary

Each stimulus contains two distinct short phrases. The nominal acoustic split
boundary is two seconds: 500 ms for Silero to report silence, followed by Work
Bench's 1,500 ms default endpoint capture. Speaker, room, and microphone tails
can shift the observed boundary, so dense probes are required.

| ID | Inserted digital silence | Repetitions | Expected result |
| --- | ---: | ---: | --- |
| C1 | 100 ms | 1 | One merged turn |
| C2 | 400 ms | 1 | One merged turn |
| C3 | 800 ms | 1 | One merged turn |
| C4 | 1200 ms | 3 | One merged turn |
| C5 | 1600 ms | 3 | One merged turn |
| C6 | 1800 ms | 3 | Boundary characterization |
| C7 | 1900 ms | 3 | Boundary characterization |
| C8 | 1950 ms | 3 | Boundary characterization |
| C9 | 2000 ms | 3 | Boundary characterization |
| C10 | 2050 ms | 3 | Boundary characterization |
| C11 | 2100 ms | 3 | Two independent turns |
| C12 | 2200 ms | 3 | Two independent turns |
| C13 | 2500 ms | 1 | Two independent turns |
| C14 | 5000 ms | 1 | Two independent turns |

The transition probes pass when all repetitions are safe and the observed
merge/split ratio is recorded. After a reference boundary is established on
the same hardware, future regression runs require the result to stay within
one adjacent 100 ms bucket.

### Phase D: cadence, queue, and lifecycle

| ID | Sequence | Expected result |
| --- | --- | --- |
| D1 | 10 short turns, 2.2-second gaps | Ten ordered final results |
| D2 | 25 short turns, 2.2-second gaps | No queue loss or stale UI result |
| D3 | Short, 60-second, then short turn | FIFO results and bounded memory |
| D4 | Switch apps during a 30-second turn | Audio and VAD remain continuous |
| D5 | Screen off during a 60-second turn | Foreground service keeps capture alive |
| D6 | Expected disconnect during active speech | Partial WAV flushes safely; transcript UI clears |
| D7 | Reconnect and speak immediately | Fresh pre-roll and segment ID; no prior text |
| D8 | Restart STT during continuous capture | Capture remains uninterrupted and queued WAV survives |

Lifecycle cases are separate from acoustic accuracy. They fail on lost audio,
an orphaned partial file, a missing queued job, stale text, or an unexpected
Bluetooth restart even if a transcript eventually appears.

## Test execution order

1. Confirm models are ready, G2 audio is stable, and the baseline level is low.
2. Run A1–A7 before long tests so minimum-duration failures are cheap to
   diagnose.
3. Run C1–C14 in ascending gap order to locate the actual merge/split boundary.
4. Run B1–B5 as the standard duration suite.
5. Run D1–D3 for queue pressure.
6. Run D4–D8 individually with lifecycle markers enabled.
7. Run B6–B8 only after the standard suite passes; record battery, memory,
   storage, and thermal state at fixed intervals.

## Required markers per completed turn

```text
[WorkBench][VAD] state=speech_started segment=<id>
[WorkBench][TranscriptUI] state=cleared reason=speech_started segment=<id>
[WorkBench][VAD] state=speech_ending segment=<id> delay_ms=1500
[WorkBench][VAD] state=buffer_cleared segment=<id> bytes=<positive> next=ready
[WorkBench][VAD] state=speech_ended segment=<id> audio_ms=<duration>
[WorkBench][Transcription] state=queued segment=<id> pending=<count>
[WorkBench][Transcription] state=processing segment=<id>
[WorkBench][Transcript][FINAL] segment=<id> text=<English text>
```

## Acceptance criteria

- Both playback boundary markers are present and name the same case.
- The observed segment count equals the expected turn count.
- `speech_ended audio_ms` contains 1.45–1.60 seconds of post-VAD PCM for every
  normally completed turn. Logcat wall time is retained as a diagnostic only
  because isolate-to-UI delivery may be batched under load.
- Buffer clearing occurs when the endpoint starts and before the same segment
  ends and is queued. Only audio captured before the endpoint transition is
  cleared; the endpoint tail remains available to the next turn.
- Segment IDs remain ordered across start, clear, queue, processing, and final
  transcript markers.
- Each completed turn produces its own WAV and TXT file.
- Every duration chunk is transcribed in FIFO order and appended durably, but
  each non-final chunk reports `VoiceRoute state=collecting ... action=deferred`.
- Only the final chunk creates the one queued action and uses the complete
  accumulated transcript for correction or delivery.
- A new `speech_started` marker clears the previous visible text immediately.
- A prior turn's distinct keywords do not appear in the next turn's transcript.
- Per-turn normalized word error rate is at most 25 percent.
- G2 audio remains at least 90 frames per second.
- No unexpected disconnect, capture failure, dropped packet, VAD restart, or
  transcription restart occurs.

Additional comprehensive-suite criteria:

- A1–A2 produce no completed segment and do not leave a `.part.wav`.
- A7 completes in all three repetitions; A3–A6 produce a recorded detection
  curve with no orphaned partial segment.
- B1–B5 produce one and only one logical turn at each duration; long turns may
  contain multiple bounded WAV/STT chunks.
- C1–C5 always merge, C11–C12 always split, and C6–C10 report a repeatable
  transition boundary.
- Every normal default close reports 1450–1600 ms in `speech_ended audio_ms`.
- Final transcript latency is recorded from `state=queued` to `FINAL`; the
  queue must drain after every case.
- The number of WAV/TXT pairs equals the number of completed turns.
- Peak memory may grow while a long job is active but must return to a stable
  band after finalization; no monotonic growth across repetitions is accepted.
- Audio transport stays at 90 fps or higher throughout all phases.

Matched-input model comparison additionally requires:

- every candidate input has the same source SHA-256 and duration;
- the ready and completed markers identify the requested model;
- WER and final-tail coverage are scored from the same expected text;
- median decode time uses at least three runs;
- resource and Android process-kill observations accompany accuracy results.

## Failure diagnosis

1. No audio activity: fix computer sink, volume, distance, or LC3 decoding.
2. Activity without VAD: inspect decoded PCM amplitude and English TTS voice.
3. Wrong turn count: inspect VAD endpoint timing and silence gaps.
4. Repeated prior words: inspect pre-roll clearing at segment finalization.
5. Missing or reordered results: inspect the transcription ledger and FIFO
   worker queue.
6. Correct pipeline with poor words: inspect speaker acoustics, clipping, and
   STT model accuracy without weakening turn-boundary assertions.

## Reference physical runs

### Current 1,500 ms default endpoint revision

On August 8, 2026, Android build 89 was installed on the representative phone
and exercised with Kokoro `af_maple` from the computer speaker. The 29.6-second
case produced one logical turn with two FIFO STT chunks. The first chunk logged
`action=deferred`; the final chunk reported `delay_ms=1500` and
`audio_ms=1500`, then entered the downstream route exactly once with the full
continuous transcript. The turn, queue, endpoint, rollover, marker-order,
transport, and safety assertions all passed.

The physical run is not an acoustic-accuracy pass: its WER was 0.813. A short
continuation trial likewise passed the VAD, endpoint, queue, transport, and
safety assertions but returned an empty transcript. Preserve both failures as
recognizer/acoustic evidence; do not use them as a fully passing STT baseline.
The automated Dart and runner regression suites independently pass the final-
only action policy and the 1,500 ms timing contract.

### Earlier 1,250 ms endpoint-tail revision

The following evidence predates the 1,500 ms default endpoint. On July 27,
2026, a representative RedMagic phone passed both sides of the 1.75-second
total-silence boundary with the packaged Parakeet 0.6B model
attested on NNAPI:

- `short_continuation` kept three utterances separated by 400 ms in one turn.
  The transcript WER was 0.00, the retained endpoint tail was 1,250 ms, capture
  held 100 frames/s, and every transport, activity, queue, and safety check
  passed.
- `queue_overlap` split three utterances separated by 1,800 ms into three
  ordered turns. Per-turn WER was 0.20, 0.00, and 0.00; every turn reported a
  1,250 ms endpoint tail; capture held 100 frames/s; and every transport,
  activity, queue, and safety check passed.
- Gemma correction completed on its GPU provider, the glasses status advanced
  through `Queued` and `Saved` before clearing after two seconds, and the WAV,
  raw transcript, and corrected transcript were exported to and indexed in the
  selected Android shared-storage folder.

Two earlier 1,800 ms boundary trials remain preserved as failures. In both, all
boundary, capture, and safety checks passed, but Parakeet consistently decoded
the first fixture phrase as "It's on the table" and exceeded the 0.25 WER
limit. The second phrase decoded at 0.00 WER after the endpoint/pre-roll handoff
fix. These failures are not omitted from the evidence or relabeled as passes.

The fixture SHA-256 values for the accepted runs are:

- `short_continuation`: source
  `5decba01fd1e42f13faaadf3779636f9780e3e314b7685effc7a04c3ad30ec05`,
  padded playback
  `3db84b815a2824002a7b23f009c41363ac416e8c458e360e22239ec2578a9ef1`.
- `queue_overlap`: source
  `0fcc1edfefdc13eafe9e62383592cc29d578717b2f74be681d248913b6efe826`,
  padded playback
  `a96c9afd9d9c6a0b838ae7680aedb70727074389d138d016e955d60d347e7cc6`.

### Earlier 1,000 ms endpoint-tail revision

The reference results below used the earlier 1,000 ms endpoint-tail revision.
They remain immutable historical evidence and must not be relabeled as
1,250 ms results.

### Marker-validated run

On July 26, 2026, the checked-in padded runner passed both a one-shot physical
Parakeet 110M check and the `short_continuation` suite case:

| Case | Baseline → peak | WER | Endpoint PCM | Decode | G2 rate |
| --- | ---: | ---: | ---: | ---: | ---: |
| One-shot, 5.22 seconds speech | 8 → 248 | 15.4% | 1000 ms | 359 ms | 100 fps |
| Short continuation, three clauses | 2 → 216 | 0% | 1000 ms | 389 ms queue-to-final | 100 fps |

Both runs used Kokoro `af_maple`, 90% computer volume, one second of leading
silence, and 500 ms of trailing silence. Both restored the original volume,
observed both playback boundaries, preserved capture, and had no unexpected
disconnect or worker restart. Their immutable artifacts were retained in
separate temporary validation directories outside the repository. The one-shot
clean stimulus SHA-256 is
`325ea8dc361d06c02d71cb2b9f3e5a63177c11996470c42fa41f63c404350063`;
the actual padded two-channel playback SHA-256 is
`2e2f6a32fa6ad2d9cc77e92f660817fe890a4c04ceb73c0b0dac40e2b4b66767`.

Fixture development preserved four earlier marker-aware trials rather than
hiding them:

| Trial | Outcome | Failure boundary |
| --- | --- | --- |
| `workbench-valid-marker-final` | Fail | A low manual volume produced only 14 levels of activity rise; no VAD turn |
| `workbench-valid-marker-final-volume90` | Pass | Manual 90% volume passed at 15.4% WER |
| `workbench-valid-marker-auto-volume` | Fail | Activity rose, but VAD did not open |
| `workbench-valid-marker-auto-volume-repeat` | Fail | Final transcript arrived at 30.8% WER, above the 25% limit |

These trials motivated automatic volume control and deterministic playback
padding. They remain part of the evidence; the padded pass does not replace
them.

### Historical pre-marker suite

The complete suite produced the following results on July 25, 2026:

| Case | Turns | Per-turn WER | Endpoint PCM | G2 rate |
| --- | ---: | --- | --- | ---: |
| Long continuous | 1/1 | 15% | 1000 ms | 100 fps |
| Short continuation | 1/1 | 0% | 1000 ms | 100 fps |
| Separated questions | 3/3 | 0%, 0%, 0% | 1000 ms each | 100 fps |
| Queue overlap | 3/3 | 20%, 0%, 0% | 1000 ms each | 100 fps |

All eight turns cleared the UI and pre-roll, then queued, processed, and
completed under the same ordered segment ID. No prior-turn text leaked into a
later result. There was no unexpected disconnect, capture failure, VAD restart,
or transcription restart. The workstation volume returned from 90% to its
original value after the run.

These older runs predate explicit playback boundaries. They remain useful
hardware characterization, but they are not accepted as the current regression
baseline. Repeat the four cases with the marker-aware runner before using their
baseline/activity values for a pass/fail decision.

## Matched-input model characterization

On July 26, 2026, all three recognizers decoded the exact same 37-second
G2-captured WAV on the same reference Android phone. This is a single-device,
single-decode characterization, not a general model benchmark.

| Model | WER | Decode time | Words | Final-tail coverage |
| --- | ---: | ---: | ---: | --- |
| Tiny Whisper | 27.1% | 4.832 s | 88 | No |
| Parakeet 110M | 4.7% | 2.013 s | 106 | Yes |
| Parakeet 0.6B | 8.4% | 6.003 s | 105 | Yes |

Parakeet 110M was both the most accurate and fastest candidate for this exact
capture. The 0.6B build also reached approximately 1.29 GB sustained PSS during
the physical suite and Android killed unrelated background processes under
memory pressure. Therefore 110M is the current device recommendation; the
0.6B result is not acceptable as the background-safe default.

The identical source removes acoustic input confounding for WER and final-tail
coverage. The timing values are provisional because each model was decoded
once; repeat M1–M3 three times before treating latency as a stable benchmark.

## Expanded physical characterization

The expanded run on July 25, 2026 established the following device-level
behavior. These are measured acoustic results, not values inferred from model
configuration. They also predate explicit playback markers and must be
repeated before becoming marker-aware regression baselines.

### Minimum speech

| Stimulus | Completed turns | Current interpretation |
| ---: | ---: | --- |
| 100–500 ms | 0 in the initial sweep | Rejected as sub-threshold |
| 600 ms | 1 of 4 | Unreliable boundary |
| 650 ms | 3 of 3 | Detected in the repetition set |
| 700 ms | 4 of 4 | Detected consistently |
| 800 ms | 1 of 1 | Detected |
| 900 ms | 1 of 1 | Detected |
| Natural 527 ms “Yes” | 0 of 1 | A short isolated word can be missed |
| 1 second | 1 of 1 | Detected and finalized |

Every detected short turn reported 1000 ms of endpoint PCM, produced ordered
queue/final markers, and preserved 100 fps transport. The 600–700 ms transition
must still be repeated across different room noise, speaker distance, and voice
levels before becoming a product guarantee.

### Silence between phrases

| Inserted silence | Initial/repetition outcome |
| ---: | --- |
| 100–1350 ms | Merged in the ascending sweep |
| 1450 ms | Merged once, split three times |
| 1500 ms | Split twice, merged once |
| 1550 ms | Split three times, merged once |
| 1650–5000 ms | Split in the ascending sweep |

For that earlier revision, the transition was probabilistic around 1.45–1.55
seconds on the tested hardware and room path. Those values are historical and
must not be used as deterministic UI promises for the current two-second
nominal default boundary.

### Continuous duration

| Measured stimulus | Turns | WER | Queue-to-final | Result |
| ---: | ---: | ---: | ---: | --- |
| 1.0 seconds | 1 | Diagnostic only | <1 second | VAD/STT completed |
| 1.29 seconds | 1 | 20.0% | <1 second | Pass |
| 5.40 seconds | 1 | 10.0% | <2 seconds | Pass |
| 15.36 seconds | 1 | 10.5% | <3 seconds | Pass |
| 29.60 seconds | 1 | 24.3% | 5.45 seconds | Pass |
| 61.16 seconds | 1 | 63.8% | 5.63 seconds | **STT coverage failure** |

The 61-second source remained one durable VAD/WAV turn, captured exactly 1000
ms of endpoint PCM, and maintained 100 fps with no disconnect or worker
restart. Tiny Whisper returned only roughly the first 30 seconds, so the
end-to-end case correctly fails transcript coverage.

### Required long-turn STT design

Do not shorten or discard the durable source WAV to work around the 30-second
model window. Add a transcription-only windowing layer:

1. Keep the original VAD WAV and job ledger entry unchanged.
2. Decode it into overlapping inference windows no longer than 25 seconds.
3. Use approximately one second of overlap between adjacent windows.
4. Transcribe windows sequentially within the STT worker so Bluetooth, VAD,
   ring input, and UI rendering remain isolated.
5. Persist each window result and progress before starting the next window.
6. Merge overlap text with normalized token de-duplication.
7. Atomically write the final TXT/JSONL result only after all windows succeed.
8. On a window failure, retry only that window and resume from persisted
   progress without replaying or deleting source audio.

After implementation, repeat B3–B8 and require full-tail keyword coverage in
addition to WER. Include a unique phrase in the final five seconds so a
truncated transcript cannot accidentally pass.
