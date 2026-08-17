# Work Bench physical transcription log contract

The validation runner consumes ordinary Android logcat plus structured Work
Bench markers. Keep marker values on one line and exclude raw audio or private
transcript context beyond the explicit test phrase.

## Required markers

Before every single-run or suite playback, foreground Work Bench and exercise
its primary button through a complete connected → **Disconnect** →
**Connect devices** → connected cycle. If the app starts disconnected, connect
it first and then perform that full cycle. Do not call Android BLE APIs or app
internals as a shortcut. Playback remains blocked until at least two fresh G2
audio summaries arrive after the final reconnect. The expected disconnect must
also recreate the native VAD detector and report its flush-ready marker before
the reconnect begins. Preserve
`connection-preflight.log` and `connection-preflight.json` with the trial.

```text
[WorkBench][Test] state=connection_initial_connect case=preflight
[WorkBench][Test] state=connection_initial_retry case=preflight  # only when startup delayed the first tap
[WorkBench][Test] state=connection_reconnect_start case=preflight
[WorkBench][Test] state=connection_disconnect_ready case=preflight
[WorkBench][Test] state=connection_audio_wait case=preflight
[WorkBench][Test] state=connection_reconnect_ready case=preflight
[WorkBench][VAD] state=flushed next=ready provider=<provider> detector=recreated
```

The initial-connect markers are conditional when the app already receives live
G2 audio. A startup retry waits for the current pipeline-ready marker, while
fresh audio that arrives during that wait takes precedence and continues the
cycle immediately. Initial G2 audio can precede completion of the app's
connection action; retry the visible **Disconnect** control until the expected
disconnect marker arrives instead of bypassing the button.

The agent-menu stress case additionally requires these markers while playback
and capture continue:

```text
[WorkBench][DebugSelector] state=opened fixture=<integer> rows=<integer>
[WorkBench][G2Display] state=generation_changed generation=<integer> owner=history pulse_in_flight=<true|false>
```

After the selector opens, at least one fresh G2 audio summary and capture
streaming marker must follow. The run fails on an Android fatal-exception,
native fatal-signal, or package ANR marker. These logs do not replace visual
inspection of the physical glasses for invalid pixels.

The host runner brackets every acoustic stimulus with markers written through
Android's `log` command:

```text
[WorkBench][Test] state=playback_start case=<id>
[WorkBench][Test] state=playback_end case=<same-id>
```

Only audio summaries before `playback_start` may contribute to the quiet
baseline. Transcripts and VAD markers before it are stale and must not be
scored. A physical run fails if either boundary marker is absent.

The standard fixture is Kokoro `af_maple` at normal speed, deterministically
peak-normalized to 95% for physical playback, 90% computer playback volume, one
second of zero-PCM leading silence, and 500 ms of zero-PCM trailing silence.
The report must identify both the clean generated stimulus and the file
actually played with SHA-256, byte length, sample rate, channel count, and
duration, the applied normalization gain, and
`playback_path=computer_speaker`. Phone/app playback is not a valid fixture and
must be rejected before a trial starts. The original computer volume is
restored in a `finally` path.

```text
[WorkBench][Capture] state=ready journal=writable
[WorkBench][Capture] state=streaming sequence=<integer>
[WorkBench][Inference] state=attested workload=vad provider=nnapi nnapi_nodes=<positive> cpu_nodes=<integer> other_nodes=<integer> nnapi_us=<integer> cpu_us=<integer>
[WorkBench][VAD] state=ready provider=<provider> recovered=<true|false>
[WorkBench][VAD] state=speech_started segment=<id> pre_roll_ms=<integer> pre_roll_bytes=<positive>
[WorkBench][TranscriptUI] state=cleared reason=speech_started segment=<id>
[WorkBench][VAD] state=speech_ending segment=<id> delay_ms=<integer>
[WorkBench][VAD] state=buffer_cleared segment=<id> bytes=<positive> next=ready
[WorkBench][VAD] state=speech_ended segment=<id> audio_ms=<integer>
[WorkBench][Transcription] state=queued segment=<id> pending=<integer>
[WorkBench][Transcription] state=processing segment=<id>
[WorkBench][Inference] state=attested workload=stt model=<model-id> provider=nnapi nnapi_nodes=<positive> cpu_nodes=<integer> other_nodes=<integer> nnapi_us=<integer> cpu_us=<integer>
[WorkBench][Transcription] state=completed segment=<id> model=<model-id> provider=<provider> audio_ms=<integer> decode_ms=<integer>
[WorkBench][Transcript][FINAL] segment=<id> text=<recognized test phrase>
```

Continuous speech is one logical turn. At 15 seconds, Work Bench searches for
the next credible end-of-word boundary: either a short low-energy inter-word
gap followed by resumed audio, or a VAD-low pause followed by resumed VAD. The
old chunk closes before the resumed PCM is written and the continuation has no
overlap. If uninterrupted speech reaches 17 seconds without either boundary,
the hard rollover prepends the final 1,000 ms of the old chunk to the
continuation. Every non-final duration chunk emits one of these paired
contracts:

```text
[WorkBench][VAD] state=speech_chunked segment=<id> reason=durationPause continuation=true
[WorkBench][VAD] state=speech_continued segment=<next-id> reason=durationPause overlap_ms=0
[WorkBench][VAD] state=speech_chunked segment=<id> reason=durationWordBoundary continuation=true
[WorkBench][VAD] state=speech_continued segment=<next-id> reason=durationWordBoundary overlap_ms=0
[WorkBench][VAD] state=speech_chunked segment=<id> reason=durationHardLimit continuation=true
[WorkBench][VAD] state=speech_continued segment=<next-id> reason=durationHardLimit overlap_ms=1000
```

The chunk receives its own queued, processing, completed, and final transcript
markers. It must not receive `speech_ended`, and `speech_continued` must not
clear the UI or arm a silence timeout. The eventual silence endpoint uses the
final continuation segment. Each non-final STT result must also report that its
downstream action was deferred:

```text
[WorkBench][VoiceRoute] state=collecting segment=<id> reason=conversation_continues action=deferred
```

It must not create a glasses `Queued` action, correction job, or agent send.
The final result uses the complete accumulated continuous transcript for the
single downstream action. The turn-suite scorer combines ordered chunk
transcripts for WER, removes only an exact suffix/prefix word match introduced
by hard-overlap padding, requires every reported `audio_ms` to remain at or
below 19,500 ms (including initial pre-roll), validates the reason/overlap pair,
and requires no Gemma correction queue marker when the fixed expected text
lacks the complete word `hey`, case-insensitively.

`speech_ending` marks the last positive VAD transition and the configured
endpoint delay. `speech_ended audio_ms` reports the PCM duration captured after
that transition. Validate `audio_ms` rather than logcat wall time because
isolate-to-UI marker delivery may be batched under load.

The default command boundary starts when VAD becomes inactive and requires an
uninterrupted 1,500 ms interval. With Silero's preceding 500 ms qualification,
that is approximately two seconds of acoustic silence. A resumed positive VAD
detection during that tail cancels finalization and keeps the audio in the same
turn. Therefore,
normal default-flow turns must report `delay_ms=1500` and approximately
`audio_ms=1500`. Selected-agent Listen Mode is a distinct flow and continues
to require `delay_ms=1000` after VAD becomes inactive.

The attestation marker is required only when the corresponding ready/completed
provider is `nnapi`. A CPU provider must not emit a synthetic NNAPI
attestation. The positive NNAPI node count comes from a silent warm-up profile
created in the app cache and deleted after its aggregate counts are logged.

For a complete turn, the clear, ending, buffer-clear, ended, queued, processing,
and final markers must retain the same segment ID and appear in that order.
`buffer_cleared` removes audio captured before the endpoint transition. Audio
captured after that marker remains in the bounded pre-roll so a near-boundary
next utterance does not lose its opening words. If speech resumes before the
endpoint completes, finalization is cancelled and that audio remains part of
the active turn.
`speech_started` must report the PCM already prepended from continuous capture;
the standard Work Bench window is two seconds (`pre_roll_ms=2000`) after the
ring buffer has filled.

Existing audio summaries are also accepted:

```text
[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 120/255 • gain 172
```

## Recovery markers

```text
[WorkBench][VAD] state=flushed next=ready provider=<provider> detector=recreated
[WorkBench][Transcription] state=restarting attempt=<integer>
[WorkBench][Transcription] state=ready recovered=true
[WorkBench][Bluetooth] state=disconnected expected=<true|false>
[WorkBench][Bluetooth] state=connected recovered=true
```

The physical preflight must observe `VAD state=flushed next=ready` with
`detector=recreated` after the expected app-button disconnect and before
reconnecting. It then requires fresh post-reconnect G2 audio summaries.
Computer-speaker playback is blocked if either the recreated-detector marker
or fresh audio is absent; an old ready marker is not a substitute.

The app may also report an audio-only recovery without cycling Bluetooth:

```text
LC3 notifications stalled; re-requesting the Hub audio stream
```

## Fatal safety markers

Any of these fails a run:

```text
[WorkBench][Capture] state=failed
[WorkBench][Capture] state=dropped
[WorkBench][Bluetooth] state=disconnected expected=false
```

## Scoring

The runner normalizes transcript text using Unicode case folding, punctuation
removal, whitespace collapsing, common compound splitting, and equivalent
single-digit number forms. It then calculates word-level Levenshtein distance.
The default pass threshold is word error rate at or below `0.25`.

Audio activity must rise by the configured amount above the pre-playback
baseline. Frame rate must remain at or above the configured minimum. A worker
restart is allowed only when a subsequent ready marker is present.

Each trial uses a fresh output directory. Passing and failing artifacts are
immutable evidence and are retained together; a later pass never invalidates
or replaces an earlier failure. Report pass ratio when repeating a case.

## Matched-input model comparison

Separate physical replays are valid transport/VAD trials but invalid direct
STT comparisons. For model ranking, every candidate must decode a
byte-for-byte copy of the same saved G2 WAV. Preserve an artifact manifest
containing its SHA-256, length, sample rate, speech duration, leading/trailing
silence, expected text, playback volume, app revision, phone identity,
provider, and thread count.

For every candidate require:

```text
[WorkBench][Transcription] state=ready model=<model-id> provider=<provider>
[WorkBench][Transcription] state=completed segment=<id> model=<same-model-id> provider=<same-provider> audio_ms=<same-duration> decode_ms=<integer>
```

Score WER and final-tail coverage separately from transport and VAD. Also
record PSS/RSS/swap, thermal state, and Android low-memory/process-kill events.
An accelerator label additionally requires a CPU-disabled native profile that
shows model nodes assigned to that hardware provider. Provider configuration,
hardware capability, session creation, and warm-up alone are not sufficient.
