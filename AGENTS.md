# Work Bench repository instructions

## Privacy and pre-push gate

Treat privacy validation as a required release check. Before every push, inspect
the complete staged diff, every new commit, and all newly tracked files for
personal information, credentials, and machine-specific configuration.

- Never commit a person's name, personal email, phone number, account name,
  home-directory path, precise location, notification content, device serial,
  hardware MAC, advertising identifier, Wi-Fi name, private hostname, or
  private IP address.
- Never commit passwords, tokens, API keys, private certificates, signing
  material, service-account files, unredacted device logs, screenshots, audio
  captures, or protocol traces containing real identifiers.
- Documentation, tests, fixtures, command examples, and reports use explicit
  generic values such as `<android-serial>`, `<g2-serial>`, `<user-home>`,
  `developer@example.invalid`, and clearly synthetic MAC addresses.
- Keep protocol constants and required third-party copyright notices intact.
  They are not personal configuration.
- Use the repository-safe commit identity
  `Work Bench Contributors <noreply@workbench.invalid>`. Review the author and
  committer fields of every outgoing commit.
- If a check finds a personal value, stop the push, remove it from code and
  history as needed, replace examples with generic placeholders, and rerun the
  complete gate. Adding a file to `.gitignore` does not remove it from an
  existing commit.

At minimum, run and review these checks before pushing:

```sh
git status --short
git diff --check
git diff --cached --check
git diff --cached
git log --format='%h %an <%ae> | %cn <%ce>' origin/main..HEAD
git grep -I -n -E '(/home/[^/[:space:]]+|/Users/[^/[:space:]]+|/mnt/[^/[:space:]]+|[A-Za-z]:\\Users\\)'
git grep -I -n -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
git grep -I -n -i -E '(password|passwd|api[_-]?key|client[_-]?secret|access[_-]?token|private[_-]?key)'
```

The searches intentionally over-report. Review each match, including binary
metadata and newly generated evidence, and only proceed when every retained
value is demonstrably generic or public.

## Screenshot handling

Treat raw screenshots and screen recordings as temporary, sensitive test
evidence. They must never be created, copied, or retained anywhere inside this
repository, including in an ignored working-tree directory.

- Before capturing, create a fresh directory outside the repository with
  `mktemp -d "${TMPDIR:-/tmp}/workbench-screenshots.XXXXXX"` and send every
  capture directly to that absolute path.
- Inspect raw captures only from that temporary directory. Never stage, commit,
  attach, or push a raw capture, even if the visible screen appears generic.
- A sanitized documentation derivative may enter `docs/images/` only when the
  user explicitly requests it. Create the derivative from the temporary source,
  remove or replace every device, account, notification, transcript, location,
  and free-form user value with generic demonstration content, then visually
  inspect it before staging. Never copy the raw source into the repository.
- Delete the temporary capture directory as soon as validation is complete.
- Before every push, review newly added image and video files with
  `git diff --cached --name-only --diff-filter=A` and stop if any are test
  captures or unreviewed derivatives. Repository-owned artwork is allowed only
  after confirming that it contains no personal or device-specific data.

## UI/UX source of truth

Always follow the inline **UI/UX examples** section on the Tools page and the
tokens in `lib/src/ui/workbench_theme.dart` for every UI or UX change.

- Use the demonstrated hierarchy: `titleMedium` for page sections,
  `titleSmall` for subsection titles, `bodyMedium` for primary copy, and
  `bodySmall` for compact status and supporting text.
- Use 16dp section padding, 12dp between groups, and 8dp between related
  controls. Every interactive target must remain at least 48dp.
- Use one filled button for the primary action, outlined buttons for secondary
  actions, and tonal buttons only for advanced tools. Button labels begin with
  a clear verb.
- Keep the interface grayscale. Green is reserved for connected or actively
  streaming status dots, and every colored state must also have a text label.
- Prefer one compact column, short labels, and one-line live status. Do not add
  nested scrolling, duplicate status, decorative cards, or a new interaction
  just to reveal guidance that can be shown inline.
- Logs and raw protocol data may use monospace; normal UI text uses the
  platform sans-serif font.

If a UI change introduces a genuinely new reusable pattern, update the inline
Tools-page examples in the same change. Before finishing UI work, run
`flutter analyze`, `flutter test`, and inspect the result on a representative
phone-sized viewport.

## Android build numbering

Increment the numeric build suffix in `pubspec.yaml` before every invocation
that produces a new Android APK or app bundle. Never reuse an Android build
number for a newly built artifact, including validation rebuilds.

- This applies to `flutter build`, direct Gradle APK/app-bundle tasks,
  `flutter run`, and any install helper that triggers an Android build.
- Increment again before retrying another Android build invocation, even when
  the prior build failed or the source did not otherwise change.
- A helper invocation that installs an explicitly supplied, already-built APK
  does not require another increment because it creates no new artifact.
- Keep the incremented `version: <name>+<build>` value in the committed
  `pubspec.yaml`; do not hide the build number in an uncommitted command-line
  override.
- After installation, verify Android reports the expected `versionName` and
  `versionCode` before accepting the build.

## Audio test source of truth

Use the checked-in
`.agents/skills/kokoro-g2-transcription-loop/SKILL.md` skill for physical G2
audio validation. The repository copy is the source of truth; keep any locally
installed copy synchronized with it.

Kokoro generation and playback are host-computer operations only. Run the
Kokoro Python environment and model on the computer, and play every fixture
through the computer's physical speaker. Never install or run Kokoro on the
Android device, never copy a Kokoro model or generated fixture to it, and never
use the phone speaker or Work Bench app for fixture playback. During these
tests, Android is only the Work Bench runtime, structured-log source, and relay
for audio captured by the G2 microphones.

Every acoustic run uses Kokoro `af_maple`, 90% computer volume, one second of
digital leading silence, and 500 ms of trailing silence. The runner must restore
the original speaker volume even after failure. Every run must contain explicit
`playback_start` and `playback_end` Android log markers. Calculate the quiet
baseline only from audio summaries before `playback_start`; ignore stale VAD
and transcript markers before it.

Before any acoustic playback, foreground Work Bench and use its primary button
for a complete disconnect/reconnect cycle. If necessary, connect first; then
tap **Disconnect**, wait for **Connect devices**, tap **Connect devices**, and
wait for **Disconnect** plus fresh post-reconnect G2 audio summaries. The
runners must enforce this preflight and refuse to start the computer speaker if
it fails. If startup temporarily disables the button, wait for the current
pipeline-ready marker and retry the same visible button; accept late fresh
audio during that wait. Never treat an old connection or streaming marker as
readiness, and never use phone/app playback.

Use a fresh output directory for every trial. Preserve the WAV, SHA-256
manifest, device log, and JSON report for passes and failures. Never rerun until
one trial passes and then omit earlier failures. Diagnose and report transport,
activity, VAD, STT, and safety boundaries independently.

Keep two test layers separate:

- Physical Kokoro replay validates speaker output, G2 capture, BLE transport,
  durable WAV persistence, VAD boundaries, queue safety, and recovery.
- STT model ranking decodes byte-for-byte copies of one saved G2 WAV. Separate
  acoustic replays are never a direct model comparison.

For model comparisons, preserve the source SHA-256 and expected text; use the
same phone, app revision, provider, thread count, and thermal starting state;
require ready/completed log markers naming the model; and report WER, decode
time, final-tail coverage, PSS/RSS/swap, thermal state, and Android
low-memory/process-kill events. Include short, 10–20 second, and longer-than-30
second captures. Never attribute VAD turn count to an STT model.

Before accepting physical evidence, run both checked-in skill test files. A
transcript alone is never a pass: playback boundaries, frame rate, activity
rise, VAD/queue ordering, transcript threshold, disconnect safety, capture
safety, and worker recovery must all satisfy the case contract.

## Accelerator claims

Treat execution-provider validation as a separate safety gate. A GPU, NPU, or
NNAPI hardware hint is not proof that a model used that accelerator. Provider
selection and a successful warm-up are also insufficient when the native
runtime can silently fall back to CPU.

- Report VAD and transcription providers separately. Ready and completed
  markers must name the provider that actually owns the worker.
- Before labeling a model accelerated, verify that the packaged native runtime
  contains and registers the provider, disables that provider's CPU device or
  reference fallback, and assigns model nodes to the hardware in a device-side
  profile or equivalent native trace.
- Validate Silero VAD and every selectable transcription model independently.
  One compatible graph does not establish support for another graph.
- Keep unsupported models on the explicit `cpu` provider. Never relabel a
  CPU-backed NNAPI, XNNPACK, or other fallback as GPU or NPU execution.
- Record the phone OS, app revision, runtime revision, model hash, provider,
  and profiling evidence for accelerator qualification. Repeat qualification
  after any runtime, model, OS, or device-family change.
- The current Gemma 4 E4B / LiteRT-LM 0.14.0 build is GPU-qualified only for
  the representative RedMagic phone family. The qualifying Android
  GPU-memory attribution moved from about 3.08 GB with the engine loaded to
  13 MB after engine release, then returned to about 3.03 GB with the next
  successful correction. Do not transfer that claim to another model,
  runtime, OS, or phone family without repeating the gate.

## Transcript correction validation

Keep Gemma correction downstream of the atomic raw STT transcript. Correction
failure, timeout, process death, invalid configuration, or missing model must
never block capture, VAD, STT, or access to the original transcript.

- Keep `<segment>.raw.txt` and `<segment>.corrected.txt` separate. Show the
  original first in the Messages tab.
- Treat the complete runtime `config.json` as private, ignored configuration
  and commit only a generic `config.example.json`. When a shared folder is
  selected, keep the editable instructions in
  `workbench-correction-prompt.txt`, validate that file before every use, and
  mirror only validated instructions into the private last-known-good config.
  Never let an invalid, partial, missing, or unreadable shared edit replace the
  last validated prompt.
- Keep the pinned Gemma weights under `models/llm/` as Git LFS chunks. Install
  with `tool/install_android_workbench.sh`, which must require an explicit
  device serial and copy models only through the app identity. Never require
  Android root or place a complete temporary Gemma copy in shared storage.
- Never log raw or corrected text outside the explicit fixed Kokoro test phrase.
  Timing metadata may contain segment IDs, stage durations, providers, model
  IDs, queue depth, memory, and thermal state.
- Run Gemma in its dedicated Android process with one engine, one serial
  worker, and one short-lived conversation per segment. Close the conversation
  on success, error, timeout, and cancellation.
- Before accepting continuous operation, run at least 15 minutes while sampling
  both app processes once per minute. Require bounded post-warm-up memory, no
  lost raw files, no capture gaps, an eventually empty correction queue, and
  recovery after killing only the Gemma process.

## Conversation analysis isolation

Treat speaker diarization and its conversation transcript as an optional,
strictly parallel consumer of an already durable speech WAV. It must never be
a prerequisite, pause point, resource-release gate, or awaited dependency of
capture, VAD, primary STT, Gemma correction, glasses updates, or agent
WebSocket delivery.

- Dispatch the primary transcription worker first. Schedule the conversation
  handoff independently, and contain every handoff, startup, inference,
  persistence, export, shutdown, and recovery failure inside the conversation
  path.
- Keep conversation analysis on its own durable queue, isolate, diarization
  models, and Parakeet recognizer. Running a second Parakeet instance in
  parallel with the primary recognizer is explicitly allowed and preferred to
  coupling the paths.
- Never pause or tear down conversation analysis before Gemma correction, and
  never make correction or agent delivery await conversation worker startup,
  inference, cleanup, memory-pressure release, or restart.
- Android memory pressure may release the optional conversation worker, but
  that release and any later restart remain asynchronous to the primary path.
  The durable conversation job must remain queued while its worker is absent.
- Preserve the original WAV and primary transcript regardless of conversation
  analysis availability or outcome. A conversation failure must not change
  the primary transcript, correction eligibility, routing, or delivery state.
- When a shared folder is selected, keep the validated speaker profile bank,
  enabled state, and match threshold in the dedicated sensitive
  `workbench-speaker-signatures.wbprofiles` recovery document. Never log its
  contents or place voice signatures in readable conversation exports or the
  SQLite history index. Existing app-private profiles win over shared recovery;
  import shared signatures only when the private profile bank is absent.
- Keep regression coverage proving primary STT dispatch is immediate even when
  conversation dispatch is slow or fails. During physical validation, compare
  timestamped primary and conversation worker markers and reject any build in
  which primary completion waits for conversation readiness or completion.

## Voice WebSocket bridge

Treat the local agent bridge as an optional downstream consumer of the durable
final transcript. A missing agent match, unavailable server, failed upgrade,
negative acknowledgement, timeout, or reconnect must never block capture, VAD,
STT, correction, file export, or access to the original transcript.

- Treat every configured endpoint as an independent runtime. Each owns its
  socket, subscription, inbound tail, acknowledgement map, FIFO, timers,
  generation, resume cursor, and connection state. Never introduce a global
  ready gate, send queue, retry timer, or ordered inbound tail across endpoints.
- Route only by a globally unique complete configured agent name. Send only to
  the endpoint that owns that name; never broadcast or fail over to another
  endpoint. An endpoint failure or configuration edit must not disconnect,
  delay, reorder, disable, or clear another endpoint's work or UI controls.

- Keep runtime `voice_websocket.json` app-private and ignored. Commit only the
  generic `voice_websocket.example.json`.
- Mirror only secret-free endpoint fields to the selected folder as
  `workbench-agent-servers.json`: endpoint ID, IP, port, fixed path,
  authentication-header mode, and agent names. Never include any secret. On
  recovery, use those fields only to prefill the editor and require the user to
  enter every secret before saving or connecting.
- Never log the configured IP address, secret, upgrade headers, request body,
  transcript text, inbound message text, server session ID, or request ID.
  Logs may contain only connection state, selected authentication mode, agent
  count, payload character count, and whether a route was sent or saved.
- Send the selected secret only during the WebSocket HTTP upgrade using the
  configured `Authorization: Bearer` or `X-Voice-Api-Token` header. Never send
  a client hello or connection message before `connection.ready`.
- Match configured agent names as complete phrases. Preserve the complete
  finalized transcript in durable storage regardless of routing outcome.
- When Gemma correction is enabled, route only the corrected live transcript
  and supply the validated saved agent names as correction vocabulary. Keep the
  raw transcript independently durable and visible before correction.
- Never route a transcription or correction job restored after app or process
  restart. A restored job may finish its local files, but only a transcript
  captured and corrected live in the current process may send a command.
- Require the matching `message.accepted` response before changing the G2
  transcript prefix from `Saved:` to `Sent:`. Every outgoing agent message uses
  this acknowledgement contract.
- Keep an acknowledgement timeout or connection loss in the bounded live FIFO
  and reuse its request ID across ambiguous retries. Only a positive
  acknowledgement, explicit non-busy rejection, queue expiry, configuration
  change, explicit user deletion from the Messages tab, or disposal is
  terminal. An explicit `agent_busy` retry uses a fresh request ID.
- Track event IDs in memory and send `connection.resume` only after a
  previously ready connection reconnects to the same saved configuration.
- Keep reconnect timers, ready timers, acknowledgement timers, subscriptions,
  and pending completers bounded and cancel them during configuration changes
  and disposal.
- Parse user-facing progress and completion text from the server's documented
  `payload` envelope. Save every acknowledged outbound message and every
  readable inbound message atomically in app-private storage, encode direction
  with the reserved `.sent.message.txt` or `.received.message.txt` suffix, and
  export both to the selected shared folder. Keep message persistence and G2
  display independent so a failure in either consumer cannot block the other.
- Treat the live app-private SQLite history database only as a performance
  index. Keep the atomic app-private records and shared Files-visible WAV/TXT
  files as authoritative durable sources. Also rotate two validated SQLite
  recovery snapshots in the selected shared folder after index updates; copy
  only reconstructable history rows, never export fingerprints or live SQLite
  sidecars, and restore only a size-bounded, integrity-checked snapshot after
  the user reselects that folder. Import the selected folder once after
  migration or folder change, and reserve a full document-provider rescan for
  explicit user refresh and cache recovery. Keep export fingerprints
  app-private and skip an unchanged indexed file during recovery sync; never
  make a bulk export block a cached history read.
- Keep every G2 BLE write bounded. Transcript and inbound-message text uses
  high priority, visual waveform writes use low priority, and a stalled write
  must time out so later FIFO statuses can still reach and clear from G2.
- Plain `ws://` sends the secret and transcript without transport encryption.
  Document that it is restricted to a trusted local connection. On Android,
  `127.0.0.1` addresses the phone itself; use an explicit development bridge
  such as `adb reverse` or a trusted LAN address for a computer-hosted server.
