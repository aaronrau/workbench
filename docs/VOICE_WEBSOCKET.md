# Voice WebSocket bridge

Work Bench can forward finalized local transcripts to an authenticated agent
server and return server messages to the G2 display. The bridge is optional and
downstream of durable capture, VAD, STT, raw transcript persistence, shared
folder export, and Gemma correction.

```text
G2 audio → durable capture → VAD → final raw transcript
                                      ├→ raw transcript file
                                      ├→ G2 "Queued: …"
                                      └→ Gemma correction
                                             ├→ corrected transcript file
                                             └→ configured agent match
                                                        ↓
                                             authenticated WebSocket
                                                        ↓
                                  ┌─ message.accepted → G2 "Sent: …"
                                  └─ retry window expires → G2 "Saved: …"
                                                           ↓ 2 seconds
                                                        clear display

Acknowledged send → durable `.sent.message.txt`
WebSocket inbound event → durable `.received.message.txt`
                        → FIFO → G2 "Received: …" → clear after 2 seconds
```

## Configuration

**Tools → Agent connection** is a registry of up to eight independent servers.
Use **Add server**, **Remove server**, and **Save servers** to manage it. Each
server accepts:

- a different IPv4 address containing four numeric octets;
- its own numeric port from 1 through 65535;
- its own masked authentication secret stored in app-private storage;
- `Authorization: Bearer` or `X-Voice-Api-Token` upgrade authentication;
- one to four case-insensitive, deduplicated agent names.

IP addresses and agent names are unique across all servers. A matched command
goes only to the server that owns that name; Work Bench does not broadcast or
fail over to another address. Home shows one horizontally scrollable
dot-and-address item per configured server IP. Each dot turns green
independently only after its own socket receives `connection.ready`. Addresses
remain UI-only and are excluded from logs.

Every endpoint owns its socket, stream subscription, inbound processing tail,
acknowledgement map, outbound FIFO, retry timers, resume cursor, and connection
generation. There is no global readiness gate or cross-endpoint queue. A
connect failure, authentication rejection, busy response, acknowledgement
timeout, reconnect, configuration edit, or inbound failure on one endpoint
cannot disconnect, reorder, or delay another endpoint. Editing an endpoint
restarts only that endpoint; unchanged sockets remain live.

The path is fixed to `/ws`. The complete validated schema is in
[`voice_websocket.example.json`](../voice_websocket.example.json). The runtime
file is `workbench/voice_websocket.json` under the platform application-support
directory. Atomic replacement prevents a partial save from becoming active,
and an invalid external edit leaves the last valid in-memory configuration
unchanged. Version-1 single-server files migrate in memory to the first
version-2 server entry and are written as version 2 on the next save.

The secret is never shown in status text and is never written to Work Bench
logs. Plain `ws://` does not encrypt its upgrade headers or messages; use it
only over a trusted local connection. Android loopback addresses the phone. A
development server on a USB-connected computer can be exposed explicitly:

```sh
adb -s <android-serial> reverse tcp:8787 tcp:8787
```

## Connection protocol

The HTTP upgrade includes exactly one configured authentication header. Work
Bench sends no client hello and waits for a version-1 `connection.ready`
message before sending agent traffic. Both the HTTP upgrade and the subsequent
ready wait have independent ten-second bounds. A stalled upgrade is abandoned,
any socket that completes after that bound is closed, and the endpoint resumes
its normal reconnect and FIFO retry schedule.

## Messages tab

The Messages tab shows `All` followed by one horizontally scrollable 48dp
agent button for every configured name across every endpoint. A selected
button carries both the canonical agent name and its endpoint ID. Filtering,
direct sends, drafts, sending state, and success or failure feedback are scoped
to that destination. A pending send on one endpoint never disables another
endpoint's agent buttons or composer. `All` continues to combine durable
messages and transcripts from every endpoint.

A direct send enters that endpoint's bounded live FIFO immediately, so the
composer never waits indefinitely for a socket acknowledgement. The draft
clears after queue admission. While delivery is active, the selected-agent view
shows the message as `Queued` with `Sending…`. If the socket write or
acknowledgement times out, the endpoint immediately leaves the ready state, its
Home dot becomes inactive, and the row says: `Unable to send. Queued and will
retry when the connection returns.` The same row provides a 48dp **Delete
queued message** action that removes only that endpoint's item. Deletion is
best-effort if a prior write reached the server but its acknowledgement was
lost.

The G2 agent selector uses the same complete agent list and windows through all
configured names instead of dropping names beyond its first visible page.

## Docker mock validation

The checked-in validation builds a temporary mock-server executable and Docker
image, starts two authenticated `/ws` servers on different container IPs with
different authentication secrets and agent names, confirms agent-name routing
plus acknowledged outbound and readable inbound signals on both, stops the first
server, and proves the second remains usable:

```sh
tool/run_multi_voice_websocket_docker_validation.sh
```

The runner gives every container, network, and image a unique task-scoped name.
Its exit trap removes both containers, the temporary network and image, and the
compiled temporary artifact on success and failure. The mock logs only signal
character counts; it does not log configured names, secrets, or message bodies.

The modern message envelope is:

```json
{
  "type": "message.send",
  "request_id": "<unique-request-id>",
  "agent": "Agent One",
  "message": "pull the latest changes"
}
```

`Sent:` is displayed only after a matching version-1 `message.accepted` with
`ok: true` and no negative `result.sent`. An explicit non-busy rejection,
missing agent match, unavailable configuration, canceled queue, or exhausted
retry window resolves the queued display to `Saved:`. A corrected default-flow
route changes from `Queued:` to `Sending:` before it waits for the
acknowledgement.

For a live Gemma-corrected command, the durable raw STT transcript must begin
with the complete word `Hey`. Gemma may then recover the canonical configured
agent from a mispronounced or poorly recognized following word. A bare agent
alias, a mid-sentence `hey`, or a larger word such as `heyday` is never
activation evidence and resolves to `Saved:` without a WebSocket send.

If the connection closes, Work Bench reconnects and resends the modern request
with the exact same `request_id`. An acknowledgement timeout resends on the
still-ready socket first. If either outcome remains ambiguous after the
in-call attempts, the command stays at the head of the bounded outbound FIFO
and retries with the same ID. Servers must treat repeated request IDs
idempotently: return the prior acknowledgement without delivering the agent
command twice. An explicit non-busy `message.error` or negative
acknowledgement is not retried.

An `agent_busy` error, acknowledgement timeout, or connection loss keeps the
command in a 32-item, app-process-only FIFO. The head retries after bounded 2,
4, 8, 15, then 30-second backoff; a matching server completion may wake an
`agent_busy` head early. Later commands cannot pass the head, preserving spoken
order. Each explicit busy rejection starts a new request ID, while a retry for
an unknown acknowledgement reuses the original request ID. A command expires
after five minutes and resolves to `Saved:` so the queue cannot remain stuck
forever. Changing configuration, disconnecting, closing the client, restarting
the app, or explicitly deleting a row from the Messages tab cancels that item;
queued commands are never restored or surprisingly delivered in a later
process. The Messages tab displays live queue state only; acknowledged messages
continue into the durable sent-message archive.

Sent-message and inbound-response index snapshots are serialized. A progress
event that arrives immediately after its acknowledgement therefore cannot race
the sent-message snapshot or leave the live Messages view behind the durable
files. Every acknowledged send also refreshes the in-memory agent list even if
a reconnect caused the tab-activity hint to be stale.

App-private message persistence and history indexing do not await shared-folder
export. Small text exports run on an independent serialized tail with a
ten-second wait bound; a slow document provider therefore cannot delay Sent
history, inbound display, or later socket work. Explicit refresh and recovery
sync retain the durable app-private file as their source.

## Double-tap progress request

After a command receives a positive `message.accepted`, Work Bench
retains that command's canonical agent name in app-process memory. A G2/R1
double tap outside an active voice memo sends:

```json
{
  "type": "summary.request",
  "request_id": "<unique-request-id>",
  "agent": "Agent One"
}
```

The request is a direct, read-only control write and does not enter, reorder, or
block the normal `message.send` FIFO. A failed or rejected command never
replaces the last successful agent. Changing the connection configuration
clears the in-memory selection so a request cannot cross server
configurations. Disconnect and reconnect retain it for the same configuration;
an app restart does not restore it.

If no command has been sent, the glasses show `Update: Send a command first`.
If the server is unavailable, they show `Update: Unavailable`. Otherwise they
show the transient state `Update: Requesting`; the server's `summary.result`
supersedes it when received. Its `result.summary`, `result.detail`, or
`result.detail_lines` text follows the same atomic `.received.message.txt`,
shared-folder export, Messages-tab, and G2 `Received:` path as other readable
inbound events. Voice memo finalization retains priority over this action.

## Single-tap history selector

When no transcript is visibly `Queued:`, the single-tap interaction expands
progress lookup into a gesture-controlled selector with `Dismiss` selected
first, a moving window over all configured agent rows, and the local Memo row
last. Tapping an agent loads every exchange retained for it in the bounded ledger and lists each
message as `[HH:mm] Message`; swipe up/down pages through the complete content
without a network request.
Every successfully indexed inbound response for that open agent reloads the
durable newest-first list and rebuilds page 1 immediately. Responses for other
agents remain saved without interrupting the current detail.
Request-ID correlation prevents an arbitrary recent response from the same
agent from replacing a saved result. The complete state machine, data model,
failure behavior, implementation, and physical-device acceptance flow are documented in
[`G2_AGENT_HISTORY_SELECTOR.md`](G2_AGENT_HISTORY_SELECTOR.md).

Only Listen Mode explicitly activated from an agent's detail page snapshots
that canonical configured agent at the first tap. Merely highlighting an agent
row or opening its detail keeps the default wake-word flow. While Listen Mode
is active, each VAD-bounded STT result appends to the visible manual transcript
and cannot invoke delivery. Preview Correction defaults Off. In that state the
second tap flushes current audio, waits for every registered STT result, and
makes the complete aggregate Gemma-eligible without requiring a spoken `Hey` or
agent name. When Preview Correction is On, each STT append instead refreshes a
serialized automatic correction preview. The second tap waits for the newest
preview and offers that cached result to the selected agent without another LLM
call. Only a corrected aggregate is offered to the selected agent;
correction-unavailable fallback retains the durable raw text.
The agent detail title ends `- Swipe to navigate` and contains the single
lifecycle/preview status beside the agent name. Its dot blinks while STT is
pending and the title reports Listening, preview queued, correcting, update
pending, current, Sending, Sent, or Saved.
The body contains only the accumulated raw or corrected transcript, without a
second lifecycle label. Swipe down from Send focuses Preview Correction; tap
toggles it, and swipe up returns focus to Send. This explicit gesture
selection is the only attention-gate bypass. Dismiss, Memo, a selection removed by a configuration
change, and speech that began before the agent was selected do not bypass
ordinary routing. The snapshot remains stable while queued STT completes.
Collection sessions and final routing ownership are in-memory only and are
never restored after a process restart.

Tap cannot accidentally dismiss an active targeted session. While the title
shows `Listening`, it stops capture, acknowledges the current VAD
flush, and waits for queued STT. Preview Off then corrects and delivers the full
transcript once. Preview On reuses the current automatic preview and never
corrects again at Send. During `Sending:` tap dismisses the detail while that
delivery continues.
Tap starts a new manual session after the detail reaches terminal `Sent:` or
`Saved:` state.

Agent-detail rendering is asynchronous with respect to delivery. Full-page G2
BLE updates retain their ordered, coalesced queue, but the app never waits for
`Sending:` or terminal text to finish rendering before queuing Gemma, sending
the corrected command, or saving an acknowledged message.

After selected-agent Gemma correction completes, the modern client places that
command in the same bounded outbound FIFO with its own correlated request ID.
The selected detail changes to `Sent:` only after the matching positive
`message.accepted` response and remains `Sending:` through bounded busy,
timeout, or connection-loss retries. An explicit rejection, queue expiry, or
cancellation resolves it to `Saved:`. Wake-word and other unselected routes use
the same acknowledgement-safe FIFO while deriving their target from the
corrected spoken invocation instead of the Listen Mode snapshot.

The client tracks the latest non-negative top-level `event_id`. After an
unexpected disconnect, it reconnects with bounded backoff, waits for the next
`connection.ready`, then sends:

```json
{
  "type": "connection.resume",
  "resume_after_event_id": 42
}
```

Changing the saved configuration clears the in-memory resume cursor so an
event ID from one server is never sent to another.

### Phone Messages agent filter and direct send

The phone **Messages** tab shows an **All** chip followed by the saved
configured agent names in one horizontally scrollable grayscale row. **All**
is selected by default and shows the ordinary combined shared-folder message
and transcript view without a message field. Selecting an agent chip filters
the body to the app-private sent and correlated received records for exactly
that agent and reveals one full-width `Message <agent>` field. Agent selection
immediately focuses that field and opens the keyboard; its **Send** action
submits the message. **All** clears focus and dismisses the composer and
keyboard.
The filtered history comes from the bounded exchange ledger, so it remains
available without requiring a shared folder and does not infer an agent from
private free-form text. The G2 selected-agent detail calls this same retained
message loader and keeps the same newest-message-first ordering. Selecting
**All**, or deselecting the active agent, restores the ordinary combined view
and dismisses the message field.
Both views initially render 20 retained entries and append the next 20-row page
as a scroll ends near the bottom. The phone index keeps the newest 100 socket
messages and 100 transcripts available to this incremental view instead of
stopping after its first page; the atomic files remain the durable source.

Every readable inbound socket message is atomically saved as a received record
before the client acknowledges its event. This includes plain-text frames,
JSON-string frames, progress/completion summaries, and readable error updates,
whether or not they correlate to a configured-agent exchange. Protocol-only
connection, ping/pong, and positive-acknowledgement frames are not message
history.

A typed message uses the chip as explicit routing intent: it does not require
`Hey` or the agent name in the field. Modern delivery uses the same direct,
single-attempt acknowledgement path as selected-agent G2 speech. Only a
matching positive `message.accepted` result clears the draft, shows success,
and archives/indexes the sent message. Rejection, busy, timeout, or connection
loss leaves the draft editable and shows an inline retryable failure. Message
text and configured agent names remain excluded from logs.

## Routing and G2 display

Configured names match as complete phrases, not substrings. Matching is
case-insensitive and the earliest match wins; a longer configured name wins a
tie. A leading spoken invocation such as `Agent One, pull the latest changes`
routes `pull the latest changes`. When the agent name appears later, the full
corrected transcript is preserved as the outgoing message.

The atomic raw transcript creates one G2 FIFO item as `Queued:` without
waiting for Gemma or the network. The segment ID follows that same item through
correction and routing, so the corrected result does not create a duplicate
display entry. Every `Queued:`, `Sending:`, `Sent:`, `Saved:`, and `Received:`
status renders in the full-height 576×288 text page instead of the compact
two-row visualizer slot. Long ordinary statuses therefore use the complete
vertical viewport and the firmware's full-page scrolling behavior.
The default live turn closes after VAD remains inactive for 1.5 seconds, or
about two seconds of acoustic silence including Silero qualification. Duration
chunks may enter the persistent STT FIFO earlier, but they only extend the
durable continuous transcript. Correction and routing occur once, using the
full transcript after the final endpoint. A single tap while this item is still
`Queued:` is consumed before the history selector. If the raw transcript starts
with the complete word `Hey`, its durable correction job moves ahead of other
ready Gemma work; an already-running inference remains ahead and is never
interrupted. The item
immediately changes to `Sending:` so a second tap cannot submit it again.
Otherwise the item resolves to `Saved:` immediately without invoking Gemma or
sending a WebSocket message. A later asynchronous raw fallback is idempotent and cannot
send that non-`Hey` transcript. When correction is enabled, saved agent names
are added to the validated correction instructions as local command
vocabulary; only the corrected result is eligible for agent matching and
WebSocket routing. Known configured agent names also receive conservative
acoustic alias guidance for leading command invocations. Routing independently
requires the complete word `Hey` at the start of the durable raw transcript and
the canonical agent phrase in the corrected transcript unless a G2 selector
row explicitly targeted that still-configured agent when speech began. A bare
acoustic variant, a mid-sentence `hey`, or a larger word such as `heyday` is not
activation evidence. Gemma may repair a
misheard agent name and command body only after the raw leading attention word
is present. The raw and corrected files remain separate. Explicitly disabling
correction permits the live raw transcript to route as a documented fallback.

The item resolves to `Sent:` only after a positive acknowledgement.
Every other outcome resolves to `Saved:`. The terminal state remains visible
for two seconds, exits the full-height page back to the visualizer, and then
yields to the latest deferred inbound item. If an inbound event arrives before the
acknowledgement, the latest transcript's `Sent:` or `Saved:` state restores the
terminal display instead of being discarded as superseded. If an inbound event
arrives during the terminal hold, only the newest inbound item waits. The
active item plus that one deferred item are the complete in-memory display
bound. This visual scheduler is independent of the durable transcription and
correction ledgers, so display timing cannot block or discard audio, files,
correction, or WebSocket routing.

After a positive acknowledgement, Work Bench starts the G2 `Sent:` update and
the app-private message save/shared-folder export concurrently. The message is
never archived as sent before acknowledgement, while shared-storage latency no
longer delays the terminal G2 update.

The agent server's `message.progress` and `message.completed` events carry
their concise user-facing text under `payload.summary` or
`payload.completion_message`. Work Bench also accepts `summary.result` text
under `result`, generic `message`, `text`, or `content` fields, nested `data`,
and non-JSON text frames. Connection and acknowledgement frames are not echoed
to the glasses. A top-level inbound agent name is shown before the message.
Inbound `Received:` items share the display FIFO and clear after two seconds,
so they cannot overwrite an active transcript status. They use the same
full-height page and restore the compact visualizer after clearing.

Every acknowledged outgoing command and readable inbound message is written
through a `.part` file and atomic rename in app-private support storage. The
final filename ends in `.sent.message.txt` or `.received.message.txt`. When
File storage is selected, completed records are exported to that shared
folder. Existing records are synchronized at startup and when the folder
changes. The **Messages** tab retains both directions with saved transcripts
and their playable WAV files. Its configured-agent chips filter exact
correlated sent/received history and expose the direct-send field described
above. The separate **Conversation** tab contains only optional
speaker-attributed turns. Normal tab loads use the app-private SQLite history
indexes; the explicit refresh action reconciles external shared-folder edits.
A persistence or export failure never blocks the G2 display or WebSocket
receive loop.

If G2 is temporarily disconnected, Work Bench retains the FIFO. A terminal
two-second hold starts only after that terminal state was written successfully.
If the hold elapsed while disconnected, Work Bench clears the stale state
before advancing after reconnection. Display and socket operations are
serialized independently so neither can stall the audio pipeline. Text states
use the high-priority BLE queue, audio-pulse updates remain low priority, and an
individual BLE write times out after two seconds so a stalled visual transfer
cannot block every later status indefinitely.

## Reliability and privacy boundaries

- WebSocket upgrade, ready, and acknowledgement waits are bounded.
- Modern `agent_busy` commands use a bounded, expiring, in-memory FIFO; its
  retry timer and pending futures are canceled on configuration changes,
  disconnect, and shutdown.
- Reconnect delay is bounded and all timers, subscriptions, and pending
  acknowledgements are canceled when configuration changes or the client
  closes.
- Socket errors never restart Bluetooth, VAD, STT, Gemma, or durable capture.
- The full raw transcript remains in its normal local file regardless of route
  outcome.
- Transcription and correction jobs restored after app or process restart may
  update their local files but can never send an old command. Only a
  transcription captured and corrected live in the current process is
  routable.
- Logs contain only generic state, authentication mode, agent count, character
  count, and sent/saved outcome. They exclude endpoint, secret, headers,
  request and server-session IDs, transcript text, and inbound content.

## Local protocol fixture

The repository includes a metadata-only local fixture for UI and device
validation. It accepts either supported upgrade header, sends
`connection.ready`, acknowledges modern messages, emits one generic inbound
event, and records only shape and character count:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --secret <local-secret> \
  --port 8787
```

Add `--busy-responses 1` to reject the first modern request with
`agent_busy`, then accept its queued retry. This provides a deterministic
device-side FIFO validation without invoking a real agent.

The checked-in Android validation target sends two synthetic commands and
requires the busy retry plus the following FIFO command to be acknowledged.
Increment the Android build suffix in `pubspec.yaml` immediately before the
`flutter run`, then use:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --secret synthetic-queue-validation-secret \
  --port 18787 \
  --busy-responses 1
adb -s <android-serial> reverse tcp:18787 tcp:18787
flutter run -d <android-serial> \
  -t tool/validate_voice_websocket_queue_on_android.dart \
  --dart-define=WORKBENCH_QUEUE_FIXTURE_PORT=18787
```

The validator exits successfully only when both sends complete in order and
the in-memory queue is empty. Remove the `adb reverse` rule after validation.

The companion physical-Android summary validator requires an acknowledged
synthetic command, resolves the ordinary double-tap action, sends the modern
`summary.request`, and requires the fixture's `summary.result` to traverse the
client's inbound path:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --secret synthetic-summary-validation-secret \
  --port 18788
adb -s <android-serial> reverse tcp:18788 tcp:18788
flutter run -d <android-serial> \
  -t tool/validate_voice_websocket_summary_on_android.dart \
  --dart-define=WORKBENCH_SUMMARY_FIXTURE_PORT=18788
```

Increment the Android build suffix before this `flutter run` and remove the
reverse rule after validation.

For an Android phone connected over USB:

```sh
adb -s <android-serial> reverse tcp:8787 tcp:8787
```

For a phone connecting directly over a trusted LAN, bind the fixture to all
IPv4 interfaces and save the computer's LAN address in Work Bench:

```sh
dart run tool/run_voice_websocket_fixture.dart \
  --host 0.0.0.0 \
  --secret <local-secret> \
  --port 8787
```

The fixture never prints the secret, agent message, request ID, or server
session ID. Use a synthetic secret and agent name for validation. The fixture
uses unencrypted `ws://`; never expose its all-interface bind beyond a trusted
local network.
