---
name: kokoro-g2-transcription-loop
description: Generate a deterministic Kokoro TTS phrase on a local computer, play it through the computer speakers for Even Realities G2 glasses to capture, collect Work Bench Android logs, score the resulting transcript, and diagnose transport, audio, VAD, transcription-worker, disconnect, and recovery failures. Use when validating or debugging the Work Bench G2 audio-to-transcript path on a physical Android device.
---

# Kokoro G2 Transcription Loop

Use the bundled runner to test the complete acoustic path:

```text
Kokoro on computer → computer speaker → G2 microphones → BLE LC3
→ durable capture → VAD → STT → structured Android log → score
```

## Host/device boundary (non-negotiable)

- Run the Kokoro Python environment, model, synthesis, padding, and playback on
  the computer only.
- Play the generated fixture through the computer's physical speaker only.
- Never install or run Kokoro on Android. Never push the Kokoro model or a
  generated WAV to Android, and never use the phone speaker or Work Bench app
  for fixture playback.
- Use Android only to run Work Bench, receive the G2 microphone stream, and
  expose the structured logs and app-private artifacts needed for validation.
- If computer-speaker playback is unavailable or inaudible near the glasses,
  stop at that failed boundary; do not substitute Android playback.

## Run the loop

1. Read [references/workbench-log-contract.md](references/workbench-log-contract.md).
2. Foreground Work Bench and use its primary connection button for a complete
   preflight cycle. If necessary, connect first; then tap **Disconnect**, wait
   for **Connect devices**, tap **Connect devices**, and wait for
   the VAD flush-ready marker, **Disconnect**, and fresh G2 audio frame
   summaries. The physical runners do this automatically and refuse to start
   playback if the app button, VAD reset, or fresh post-reconnect audio is
   unavailable. If the connection button is initially
   disabled during app startup, the runner waits for the current pipeline-ready
   marker and retries that same visible button. Late fresh audio also satisfies
   the wait immediately; it is never discarded merely because connection took
   longer than the first probe. If initial connection work still owns the
   button after audio begins, the runner retries the visible **Disconnect**
   control until the expected disconnect marker arrives. Never infer readiness
   from an old connection marker. With more than one Android device attached,
   pass the intended Work Bench device through `--serial`.
3. Prepare the isolated computer-side runtime:

   ```bash
   python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_g2_loop.py prepare
   ```

4. Run the physical test from the repository root with a new output directory
   for every trial:

   ```bash
   python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_g2_loop.py run \
     --text "Work Bench audio safety check number seven. The glasses should transcribe every word." \
     --output-dir /tmp/workbench-kokoro-run-001
   ```

   The default voice is `af_maple` (speaker ID `0`), an American-English
   Kokoro voice. The only accepted speaker IDs are `0` (`af_maple`), `1`
   (`af_sol`), and `2` (`bf_vale`) so an English test cannot accidentally use
   one of the model's Chinese voices. The clean generated source is
   deterministically peak-normalized to 95% for physical playback so Kokoro
   model output level cannot silently change the acoustic fixture. The report
   records the applied gain and hashes both the clean and actually played WAVs.
   Computer playback defaults to 90% and the runner restores the original sink
   volume in `finally`. It also adds one second of digital silence before speech
   and 500 ms after speech so sink startup cannot clip the first test words. The
   runner refuses a non-empty output directory so prior passing or failing
   evidence cannot be overwritten. The runner temporarily enables only the
   Android `WorkBenchTest`, `flutter`, and `WorkBench` log tags so OEM-wide
   silent log defaults cannot erase the evidence, then restores every prior tag
   value.

   Physical playback is computer-speaker only. The runner has no phone-speaker
   option and rejects `--phone-speaker`; never push the fixture to the Android
   device or trigger playback from the app. If the workstation sink is not
   physically audible near the glasses, stop and report that hardware setup as
   the earliest failed boundary.

5. Inspect `report.json`, `device.log`, `stimulus.wav`, and the padded playback
   WAV in the output directory. The report records SHA-256, byte length, sample
   rate, channel count, and duration for the generated and actually played
   files. Do not accept a transcript-only pass. Require all of:

   - both host-controlled playback boundary markers were observed;
   - the app-button disconnect/reconnect preflight completed, VAD reset to a
     reusable state, and fresh G2 audio frames arrived before computer
     playback;
   - G2 audio frames continued during playback;
   - audio activity rose clearly above samples recorded before the playback
     start marker;
   - a final transcript arrived;
   - normalized word error rate met the configured threshold;
   - no unexpected G2 disconnect occurred;
   - no durable-capture failure occurred;
   - any transcription-worker restart recovered without stopping capture.

6. For VAD endpoint and multi-turn timing, run the English computer-speaker
   suite:

   ```bash
   python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_turn_suite.py \
     --output-dir /tmp/workbench-kokoro-turn-suite-001
   ```

   It exercises one continuous long phrase, short phrases with 400 ms pauses,
   separate questions and closely queued turns with 2.2 second pauses. It
   verifies the 1,500 ms retained default endpoint tail, the
   nominal two-second acoustic-silence boundary, a soft 15-second inter-word/
   VAD-pause boundary with a 17-second overlapped hard fallback, one real
   endpoint per logical continuous turn, boundary-deduplicated combined
   transcript accuracy,
   every intermediate chunk defers its downstream action, no Gemma correction
   for fixtures without the complete word `hey`, segment ordering, buffer
   clearing, UI clearing, and safety independently for each turn. The runner
   restores the original computer speaker volume even when a case fails. It
   also re-enables the required Android log tags after connection preflight and
   restores their original values afterward, so valid playback cannot silently
   produce an empty `device.log`.

   Select the comprehensive duration or silence-boundary profiles when the
   task requires shorter speech, longer continuous speech, or different pause
   timing:

   ```bash
   python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_turn_suite.py \
     --profile duration \
     --profile boundary \
     --output-dir /tmp/workbench-kokoro-comprehensive-001
   ```

   The duration profile spans 100 ms clips through approximately 60 seconds.
   The boundary profile probes inserted silence from 100 ms through 5 seconds,
   with dense characterization points around the nominal two-second acoustic
   split boundary. Use `--repeat 3` with selected `--case NAME` options for
   three-run boundary stability checks.

   For the continuous queue/display race, run the five-minute stress case. It
   opens the synthetic agent selector 15 seconds after computer-speaker
   playback starts, while G2 audio remains active, and requires the history
   display generation plus continued capture and audio after the menu opens:

   ```bash
   python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_turn_suite.py \
     --profile stress \
     --result-timeout 180 \
     --output-dir /tmp/workbench-kokoro-agent-menu-stress-001
   ```

   The stress case requires at least 15 ordered forced chunks in one logical
   turn, one final endpoint/action, no Android crash marker, and the normal
   transport, VAD, STT, queue, and transcript checks. A logged display-owner
   transition is protocol evidence; visually inspect the physical glasses for
   invalid pixels before accepting the display result.

## Compare STT models without acoustic confounding

Do not rank STT models from separate speaker replays. Room noise, speaker
level, G2 placement, codec loss, and VAD boundaries make those different
inputs, even when Kokoro generated the same phrase.

Use two deliberately separate test layers:

1. Run the physical Kokoro loop once to validate speaker → G2 → BLE → durable
   WAV → VAD. Preserve the resulting G2-captured WAV.
2. Record the captured WAV's SHA-256, byte length, sample rate, duration, and
   exact expected text.
3. Decode byte-for-byte copies of that one WAV with every candidate model on
   the same phone. Keep runtime provider, thread count, app revision, and
   thermal starting state fixed.
4. Require the `state=ready model=<id> provider=<provider>` and
   `state=completed ... model=<id> provider=<same-provider> audio_ms=<n>
   decode_ms=<n>` markers to match the intended candidate. A display label or
   build argument alone is not proof that the requested model ran. GPU/NPU
   claims additionally require a CPU-disabled native profile that assigns
   model nodes to the named hardware provider; warm-up alone is insufficient.
5. Report WER, decode time, word count, and a unique final-five-second tail
   phrase for each model. Include at least one short capture, one 10–20 second
   capture, and one capture longer than 30 seconds.
6. Capture PSS/RSS/swap, thermal state, and low-memory/process-kill logs.
   Repeat decode timing at least three times and report the median.

Keep the physical transport/VAD results in a different table from matched-WAV
recognizer results. VAD turn count belongs to the physical pipeline and must
never be attributed to the STT model. A model recommendation is invalid if the
candidate inputs differ, the source hash is missing, or background-process
kills are omitted.

## Diagnose in dependency order

Always fix the earliest failing boundary, then repeat the same phrase.

1. **No transport:** repair G2 connection/audio initialization.
2. **Transport but no activity rise:** verify speaker output, physical distance,
   LC3 frame routing, and decoder output.
3. **Activity but no VAD segment:** inspect decoded PCM level and VAD thresholds.
4. **VAD segment but no final transcript:** inspect the transcription supervisor,
   job ledger, model readiness, and worker restart.
5. **Transcript with poor score:** inspect clipping, decoder gaps, segment
   boundaries, language/model selection, and timestamps.
6. **Disconnect or capture failure:** repair that safety boundary even if the
   transcript passed.

Repeat until the report passes or a reproducible external hardware condition
prevents progress. Preserve and disclose every failing report before changing
code. Repeating a flaky case until it passes does not replace the failed trials;
report the pass ratio and each distinct failure boundary.

## Safety rules

- Keep the raw capture/journal path independent from TTS playback and STT.
- Never delete captured audio because transcription failed.
- Never restart Bluetooth merely to restart transcription.
- Keep `Disconnect` available whenever any wearable link is active.
- Do not upload captured audio, transcripts, device identifiers, or logs.
- Use a fixed phrase and speaker ID while comparing code iterations.
- Use an identical captured-WAV hash while comparing STT models.

## Runner commands

- `prepare`: create an isolated Sherpa-ONNX environment and download the
  official quantized Kokoro model.
- `preflight`: exercise only the mandatory Work Bench app-button
  disconnect/reconnect and fresh-audio gate without playing a fixture.
- `generate`: synthesize only, useful for checking workstation playback.
- `run`: synthesize, capture logcat, play the phrase, and write a JSON report.
- `score-log`: rescore an existing device log without replaying audio.
- `kokoro_turn_suite.py`: run the fixed English VAD/turn-boundary sequence.
- `python3 .agents/skills/kokoro-g2-transcription-loop/scripts/test_kokoro_g2_loop.py && python3
  .agents/skills/kokoro-g2-transcription-loop/scripts/test_kokoro_turn_suite.py`:
  verify playback boundary scoring, quiet-baseline isolation, padding,
  immutable artifact handling, mandatory app-button reconnection,
  computer-only playback, stale-transcript rejection, and suite integration.

Run
`python3 .agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_g2_loop.py COMMAND --help`
for options.
