# Independent conversation analysis

Conversation analysis is an optional, disabled-by-default consumer of the
durable speech WAV. It identifies speakers and transcribes their turns without
participating in the primary transcript, correction, glasses-display, or
WebSocket route.

## Boundary

```text
G2 LC3 → journal → decode → VAD → atomic speech WAV
                                  ├─ existing STT → raw transcript
                                  │                → Gemma → agent WebSocket
                                  └─ non-awaited path-only handoff
                                     → conversation isolate
                                       ├─ pyannote segmentation
                                       ├─ TitaNet speaker signature
                                       └─ independent Parakeet 110M STT
                                          → conversation TXT + JSON
                                          → app-private SQLite turns
```

The live LC3 and PCM buffers have one owner. Conversation analysis receives a
file path only after VAD closes the same WAV already used by the existing STT
worker. It therefore allocates no second live audio buffer and cannot apply
backpressure to capture.

`ConversationAnalysisService` serializes jobs through a durable app-private
ledger. `ConversationAnalysisSupervisor` owns the native models in a separate
Dart isolate. An exception terminates or fails only that worker; the supervisor
restarts it with bounded backoff and resubmits its current job. Queue,
analysis, speaker-model, export, and SQLite failures log metadata-only status
and leave capture, VAD, ordinary STT, Gemma, BLE, and WebSocket behavior
unchanged.

The native conversation worker is loaded on demand when a durable WAV is
queued, remains warm for up to 30 seconds between nearby turns, and releases
its independent Parakeet and diarization allocations after the queue drains.
It never pauses, releases, or waits for its worker on behalf of Gemma. The
primary STT dispatch happens first, while the conversation handoff is scheduled
independently; diarization startup, analysis, transcription, native cleanup,
storage, and export cannot delay correction or agent delivery. The main STT
worker and conversation worker may therefore keep two separate Parakeet
instances active and run them in parallel. Android memory-pressure handling
may release the optional worker independently, but the primary path never
awaits that release.

## Enrollment and matching

Enable **Tools → Conversation analysis → Enable speaker-labeled
conversations**. When no primary profile exists, Home asks for three clear
single-speaker utterances and shows progress after each accepted sample. Each
sample is persisted before the next prompt, so enrollment resumes after an app
restart. Enrollment rejects a segment when diarization detects multiple
speakers or when a later sample does not match every earlier sample. A rejected
sample does not advance progress. Only after all three samples agree does the
profile become eligible to identify speech as `You`.

Each local diarization cluster produces a normalized TitaNet embedding:

- short-turn clustering uses a `0.01` cosine-distance cut, with profile
  matching responsible for reuniting repeated turns;
- primary and non-primary profiles use the persisted Tools setting for the
  signature threshold. It defaults to the validated `0.64` boundary and is
  adjustable from `0.50` to `0.90` in `0.01` steps. Lower values accept more
  voice variation and raise false-match risk; higher values require a closer
  match and raise false-negative risk. Every pair among the three enrollment
  samples must meet the selected value, and the completed `You` profile keeps
  that same value for future speech;
- a strong match at or above `0.78` updates its bounded centroid;
- a weaker match creates `Speaker 2`, `Speaker 3`, and so on;
- overlapping diarization spans are labeled `Overlapping speakers` instead of
  being assigned to `You`.

Each profile keeps its normalized centroid plus at most six recent signatures.
Matching uses the best saved signature so normal microphone and room variation
does not erase a previously good enrollment. The lower reuse threshold does
not update the saved signature bank unless the match also reaches the separate
`0.78` learning threshold, limiting drift from borderline matches. Speaker
profiles are app-private and persist across restarts. The bank keeps one
primary profile and the 16 most recently updated non-primary profiles. When a
new unknown speaker arrives at that limit, the oldest inactive non-primary
profile is evicted; startup also compacts profile banks created by older
unbounded builds. Each new app-private conversation turn also retains its
normalized voice signature so later `You` enrollment can reconcile the turn
even after its temporary non-primary profile leaves the active bank. Voice
signatures are never placed in the shared-folder text export or SQLite index.
When a shared folder is selected, the validated bounded profile bank plus its
enabled state and match threshold is also mirrored to the dedicated sensitive
`workbench-speaker-signatures.wbprofiles` recovery document. This document is
sensitive biometric data even though it is not a readable conversation export;
protect or delete it with the same care as the selected folder. A reinstall
imports it only when no app-private profile bank exists.

## Output and history

For `<segment>.wav`, successful optional analysis writes:

- `<segment>.conversation.txt` — readable blocks labeled by speaker and time;
- `<segment>.conversation.json` — atomic structured turn metadata;
- app-private retained metadata under
  `files/workbench/conversation/<segment>.conversation.json`;
- one row per turn in the app-private SQLite history index.

The SQLite row stores the conversation and turn IDs, speaker ID and label,
text, start/end milliseconds, match confidence, primary/overlap flags, and
update time. The **Conversation** tab renders primary `You` turns on the right
and other speakers on the left as aligned text with grayscale speaker markers.
The text file is also exported to the selected shared folder when one is
available. If the exact app-private conversation index is missing after an
older reinstall, Work Bench parses those readable `.conversation.txt` blocks
back into display-only SQLite rows. Recovered rows retain speaker labels,
timings, and text; unavailable historical confidence and per-turn signatures
are not invented.

Tools exposes one **Reset speaker identification** action; there is no reset
control in the Conversation tab. The action removes only the primary voice
profile, retains other saved speakers and conversation history, and
automatically starts a fresh three-sample calibration. The reset remains busy
until the current result and profile persistence are complete, preventing a
late worker result from restoring the removed signature. A speech segment that
began before the reset is not accepted as a replacement enrollment sample.
Only one enrollment sample is analyzed at a time, and the action is disabled
while analysis is pending. Reset also restores the threshold setting to
`0.64`; it can be adjusted before or between enrollment samples, but not while
a sample is being analyzed.

After the third accepted sample, Work Bench compares the new `You` signature
bank with every retained per-turn signature and with legacy turns through
their still-retained speaker profiles. Matching non-overlap turns are rewritten
atomically as `You` in the app-private JSON and readable conversation text,
then reindexed for the Conversation tab and re-exported when a shared folder is
selected. Matching duplicate profiles are folded into `You`, so the same
calibration is used for future speech. A persisted reconciliation-pending flag
makes this pass idempotent after an app or process restart. Overlap labels and
unrelated speaker profiles remain unchanged.

Atomic WAV, text, and JSON files remain the durable records. SQLite is the
fast UI index and may be rebuilt independently.

## Models and installation

The optional worker uses CPU providers independently for:

- Sherpa-ONNX INT8 pyannote segmentation 3.0;
- NeMo TitaNet Small speaker embeddings;
- Parakeet 110M conversation transcription.

The two diarization models are pinned under `models/diarization/` with Git LFS
and SHA-256 manifests. Copy them only into the selected installed app:

```sh
git lfs pull --include='models/diarization/**'
(cd models/diarization && sha256sum --check SHA256SUMS)
./tool/stage_android_diarization_models.sh --device <android-serial>
```

`tool/install_android_workbench.sh --device <android-serial>` performs this
step with the other pinned models.

## Validation

Automated acceptance includes:

- three-sample consistency at adjustable persisted thresholds, default-value
  reset, signature-bank calibration and migration, per-turn signature
  normalization, centroid updates, and JSON validation;
- crash-resumable historical `You` relabeling, duplicate-profile folding,
  readable-text rewrites, and SQLite refresh;
- bounded legacy-profile compaction and reset cutover to the next newly started
  speech segment;
- atomic profile, pending-job, and conversation-record recovery;
- primary STT dispatch completes without awaiting conversation handoff, and a
  conversation dispatch failure remains isolated from the primary path;
- SQLite method-channel indexing and ordered conversation reads;
- enrollment, disabled, error, paging, 48dp target, and speaker-turn UI states;
- the complete existing Flutter test suite;
- both checked-in Kokoro skill contract test files before physical evidence.

`tool/validate_conversation_diarization.dart` drives the native worker directly
against clean 16 kHz WAVs. Pass three enrollment WAVs with `--enrollments`; its
legacy singular option reuses one deterministic fixture three times. The
alternating-turn case enrolls `af_maple`, runs
`af_sol`, `af_maple`, `bf_vale`, and `af_maple` turns twice, requires three
stable profiles, enforces a per-turn WER ceiling, and kills the worker with its
first turn in flight to verify queued-job recovery. On Linux, make the
Sherpa-ONNX Linux library directory available through `LD_LIBRARY_PATH` before
running the tool. Its optional `--signature-threshold` argument overrides the
default `0.64` independently from `--cluster-threshold`.

Physical acoustic testing continues to treat the existing Kokoro `af_maple`
baseline as the transport/VAD/STT safety contract. Alternating-speaker tests
add speaker assignment and worker-restart checks without substituting for or
discarding that baseline.
