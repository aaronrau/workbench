# G2 agent history selector design

Status: implemented.

## Goal

An ordinary G2/R1 tap opens a compact, private history selector on the glasses.
The selector gives quick access to the retained acknowledged messages for each
configured agent and to the latest saved Memo. Swipes move the selection, tap
opens the selected conversation history, and a final tap dismisses the
interaction.

This flow extends, rather than replaces, the existing behavior:

- double tap outside Memo remains the fast progress request for the last
  successfully sent agent;
- double tap during an active Memo still finalizes that Memo;
- continuous LC3 capture, VAD, STT, correction, durable files, and ordinary
  WebSocket delivery remain independent of the selector.

## Product interpretation

The selector renders every agent option with a `[Agent] content` first row.
Carriage returns, newlines, and repeated whitespace are collapsed to spaces
before the row is measured; overflow after the second measured row is
ellipsized. Opening the option loads every exchange retained in the bounded
agent ledger for only that agent. The
target glasses layout contains:

1. `[x]`
2. up to five configured agent rows
3. `Memo`

`[x]` is always the initially selected row. This makes opening the selector
safe: a second tap closes it unless the user intentionally swipes to private
content.

The target workflow assumes five configured agents. If more than five are
configured, the selector uses the five agents with the most recent
acknowledged sends, while retaining their relative order from the saved
configuration. The phone's Messages view remains the complete history.

## Glasses layouts

### Selector

Every option occupies one or two rendered lines. Carriage returns, newlines,
and repeated whitespace in private content are collapsed before width
measurement, so source formatting never forces a selector line break. Agent
rows start `[Agent] content` without an elapsed-time element. Memo starts
`Memo - content`; measured overflow
continues on one aligned second row and is ellipsized there.
`[x] - Swipe to Select` remains a
fixed one-line header. There is no page counter. Every rendered line reserves a
fixed 25-pixel pointer gutter. The selected gutter includes two spaces after
`>`, and the empty and continuation gutters have exactly the same measured
width, so moving the cursor cannot shift or rewrap the content. A representative
short selector is:

```text
 >  [x] - Swipe to Select
     [Agent One] latest received update
     [Agent Three] latest sent command
     [Agent Five] earlier received update
     [Agent Two] No messages
     [Agent Four] No messages
     Memo - latest saved memo
```

When a normalized preview is too wide, it uses one aligned continuation row
and ends with an ellipsis there:

```text
 >  [x] - Swipe to Select
     [Agent One] latest sent command that continues
     on the second measured row…
     [Agent Two] another command that continues on
     its second measured row…
```

Complete one- or two-row entries are adaptively windowed inside the seven rows
beneath the fixed header. The ninth physical row stays unused so the firmware's
own full-height scrolling path cannot claim the swipe. While the next entry
fits, swipes move
only `>`.
When it does not fit, the minimum number of complete entries moves offscreen so
the selected entry and its following context remain visible. Selection wraps
between `[x]` and Memo, and entries are never split across viewport boundaries.

The marker is the only selection indicator, so the layout remains grayscale
and does not rely on color. Wrapping uses G2 pixel advances instead of a fixed
rune budget. The complete eight-row selector remains bounded to 2,000 UTF-8
bytes.

History rebuilds the active Hub surface as a dedicated borderless 576x288 text
page with a four-pixel firmware inset. The selector and every detail-page
rebuild reuse that inset, so a physical swipe cannot move the first glyph at
the left display edge. Host layout uses one shared calibrated wrapping budget.
Standalone glyph advances overestimate the physically observed firmware width,
so the utility reserves an 18-pixel right-side safety budget and adds a 50-unit
calibration. Selector content receives a separate 25-pixel pointer gutter and
is limited to two rows independently of selection. The physical container
remains 576 pixels wide and its inset content width is 568 pixels. A
second startup/create command is not sufficient after the visualizer exists;
the firmware retains the visualizer's compact 520x64 gesture slot, clipping
the lower rows and producing a misleadingly short scroll indicator. Dismissal
rebuilds the visualizer page and resumes pulse rendering.

### Conversation message history

Selecting an agent uses the same retained `AgentMessageView` list as the
phone's selected-agent Messages tab. The app-private message files are the
durable source; a missing or cleared performance index is rebuilt from every
saved sent/received file whose complete agent prefix matches a configured
agent. Socket configuration saves retain that index. Messages are sorted
newest-first and listed using their local 24-hour timestamp. Agent and
direction labels are omitted from the rows:

```text
   [Agent One] - Swipe to Navigate
 >  • Listen Mode - Tap to start
[14:33] <correlated completion>
[14:32] <first correlated progress update>
[14:31] <most recent command>
[09:08] <previous command>
```

Commands and responses may wrap because this is a detail view, not a selector
row. Every agent detail reserves two fixed rows and seven message or transcript
rows. Opening it does not enable speech targeting. A second tap changes the
Listen row's active
arrow from `>` to `<` without shifting the title; only then does speech directly
target the agent named once in the title. The title remains
`[Agent One] - Swipe to Navigate`, and the selected row becomes
` <  • Send transcript - Tap`. Swipe up stops Listen Mode and moves the active
`<` control to the agent title. Tapping that title returns to the selector;
swipe down returns focus to Listen Mode. During an active session, swipe down
from Send advances a page. While the title owns focus, another up swipe returns
one page. A swipe-up
cancel clears the transient speech overlay and restores the exact history page
that was visible when Listen Mode started. VAD endpoints do not stop the manual
session: each endpoint queues an audio chunk for FIFO STT, and every completed
chunk refreshes the body with only the accumulated transcript text. Later
speech keeps appending to the same display owner. Preview Correction is always
enabled and has no
selectable control. Every appended STT result automatically refreshes one
serialized correction preview. Only the next tap on Send stops capture, waits
for the final VAD flush and all queued STT, then changes the second row to
`Sending - Wait`. Further taps are consumed until delivery finishes. Send
reuses the current preview without another LLM call. The
detail returns to newest-first durable history after acknowledgement.
Every successfully indexed matching-agent response replaces the open detail's
durable body and rebuilds page 1 immediately. A nonmatching response is saved
without interrupting the current agent. Active listening or sending controls
remain intact while their underlying history refreshes.
Memo details retain one title and eight body rows and page immediately. Both
layouts stay within the nine-line viewport and prevent the firmware's native
scroll track from appearing beside the app thumb. Pages stop at either boundary
instead of wrapping. The last content row of each page repeats as the first
content row on the next page, preserving the wearer's reading position. The
selector preview for each agent comes from that agent's newest indexed durable
message by timestamp, regardless of sent or received direction. Row ordering
and the compact age use the newest received direction only. Detail history
keeps every indexed durable message and never truncates to that preview bound.

Every detail page begins with `[ Memo · Tap to dismiss ]` or the two agent rows
`   [<name>] - Swipe to Navigate` and
` >  • Listen Mode - Tap to start`. Conversation rows use
`[HH:mm] Message`, strip
an identical stored agent prefix first, and never repeat the agent name in the
history body. Explicit LF, CRLF, and CR line breaks in saved Memo or message
text remain hard line breaks; blank paragraph separators remain blank display
rows. Only horizontal spacing is normalized before long lines are wrapped.

Detail bodies are wrapped and paginated once per content revision, then reused
while the wearer scrolls. A logical page turn keeps the current EvenHub page,
gesture-capture container, and image container alive and serially upgrades only
the bounded text and thumb bitmap. A full-page rebuild is reserved for a real
structure change, such as entering or leaving multi-page detail mode. This
avoids racing the firmware page lifecycle on every physical swipe.

Multi-page detail mode adds one firmware-valid 20-by-144-pixel image container
centered at the right edge. The container never moves or changes size while
paging. Inside its bitmap, four pixels form one continuous solid rectangle,
with 14 black pixels before it and a two-pixel black mask after it. The black
pixels blend into the display and cover the firmware edge artifact, so only the
proportional thumb is visible as it moves through the fixed container. A
one-page detail does not need an indicator and therefore does not create the
image container. The image overlays the edge of the full 576-pixel text
surface. Its black mask ends at the right display edge while the visible thumb
stops two pixels before it. There is no outline or background track.
Selector pages do not create the image container. The generated BMP and its
wire header are validated again before upload. Its dimensions must remain in
the firmware's inclusive 20–288 by 20–144 image range, and every decoded thumb
pixel must be palette index 0 or 15—full black or full white, never a partial
gray value.

### Empty Memo or agent row

Memo is always present:

```text
Memo - No saved memo
```

An agent with no positively acknowledged command is also retained:

```text
[Agent Two] No messages
```

Tapping either empty option shows the same state below a title containing
`Tap to dismiss`; it never fabricates or sends agent work. An acknowledged
command without a correlated response remains visible as its timestamped sent
message.

## Gesture contract

### Selector closed

| Gesture | Result |
| --- | --- |
| Tap | Open selector with `[x]` selected |
| Double tap | Request progress for the last successfully sent agent |
| Swipe up/down | Preserve the existing ordinary gesture behavior |
| Double tap during active Memo | Finalize Memo; do not open the selector |
| Tap during active Memo | Memo retains display ownership; do not open the selector |

### Selector open

| Gesture | Result |
| --- | --- |
| Swipe up | Select the previous row, wrapping before `[x]` |
| Swipe down | Select the next row, wrapping after the last row |
| Swipe between visible agent rows | Move only the cursor while the complete selected block fits |
| Swipe to the last visible entry | Scroll the minimum whole blocks needed to reveal its next entry |
| Tap on `[x]` | Clear the selector and restore the audio visualizer |
| Tap on Memo | Show the most recent saved Memo, or the empty state |
| Tap on an agent with a command | Show all of its retained timestamped messages |
| Tap on an agent without a command | Show `No conversation yet`; do not send |
| Double tap | Consume without a second request so selector state stays deterministic |

### Detail page

| Gesture | Result |
| --- | --- |
| First tap on an agent | Open its history with Listen Mode inactive |
| Tap inactive Listen Mode | Change the Listen arrow from `>` to `<` and enable direct speech targeting |
| Tap active Listen/Send control, with or without speech | Stop capture and wait for queued STT, then reuse the automatic correction preview. An empty session is saved without sending |
| Swipe up while the Listen row owns focus | Stop Listen Mode if active, restore history, and move `<` to the agent title |
| Tap while `< Agent` owns focus | Return to the selector without closing all history |
| Swipe down while the agent title owns focus | Move focus back to the Listen row |
| Swipe down while an active Listen/Send row owns focus | Show the next transcript page |
| Swipe down while an inactive Listen row owns focus | Show the next message page |
| Swipe up while the agent title owns focus | Show the previous message page |
| Swipe up/down in Memo detail | Show the previous/next Memo page |
| Tap during `Listening` while Send owns focus | Stop capture and flush/wait for STT, then reuse the latest automatic preview |
| Tap during `Sending:` | Consume the tap without changing the page or starting another delivery |
| Tap after `Sent:`/`Saved:` | Start a new Listen Mode turn and restore retained history beneath the controls |
| Double tap | Ignore |

The interaction stays open until the user taps. There is no automatic
two-second clear on selector or detail pages.

## State machine

```text
normal
  └─ tap ─► selector([x] selected)
               ├─ swipe ─► selector(other row selected)
               ├─ tap [x] ─► normal
               ├─ tap Memo/empty ─► detail
               └─ tap agent ─► retained-message detail

detail
  ├─ Memo swipe up/down ─► previous/next bounded detail page
  └─ agent tap ─► Listen Mode selected
                      ├─ swipe down ─► next bounded page
                      ├─ swipe up ─► Listen Mode inactive
                      ├─ VAD endpoint ─► FIFO STT chunk + visible transcript
                      │                    └─ auto-correct latest revision
                      └─ second tap ─► flush + wait for STT
                                           └─ reuse preview + send
```

Only one selector interaction may exist. Opening a new interaction is
impossible until the current one is dismissed.

## Defining "sent" and "response"

A command becomes selectable as sent only after:

- a modern `message.send` receives a positive matching `message.accepted`; or
- a legacy command is written successfully, consistent with the existing
  legacy contract.

A rejection, acknowledgement timeout, queue expiration, configuration change,
or failed legacy write does not replace the prior successful command.

A response belongs to a modern command only when:

- `message.progress` or `message.completed` carries the command's
  `request_id`; or
- `summary.result` carries a summary request ID that the selector explicitly
  associated with that command.

A readable event that names the same agent but has no matching request
correlation is saved as normal inbound history but is not silently attached to
the selected command. This prevents a response to older work from appearing as
the answer to newer work.

Legacy messages have no durable correlation contract. While the current app
process is alive, a readable event may be associated with the latest live
legacy send for the same agent. After restart, an uncorrelated legacy command
remains visible without a fabricated response; opening history does not send a
new request.

## Summary request behavior

Agent-history selection is read-only. The separate double-tap progress shortcut
can still send a modern summary request for the last acknowledged agent:

```json
{
  "type": "summary.request",
  "request_id": "<unique-summary-request-id>",
  "agent": "Agent One"
}
```

Legacy mode sends:

```json
{
  "type": "local",
  "agent": "Agent One",
  "message": "progress_summary"
}
```

The summary request remains an optional downstream operation. It does not
enter or reorder the normal command FIFO. Capture, VAD, STT, correction, raw
files, corrected files, and access to the original transcript remain
unaffected.

Each connect and send attempt is bounded. Selecting an agent never waits for a
connection, acknowledgement, or new agent response; it reads only the durable
exchange ledger and its direct message-file paths.

## Memo behavior

Memo is local and is never sent to the agent WebSocket by this selector.

- The Memo option starts `Memo - content`, may use one aligned continuation
  row, and ellipsizes further overflow.
- Tapping Memo opens the bounded saved note with the action in its title.
- An active Memo owns the display and prevents the selector from opening.
- If Memo starts while the selector is open, Memo preempts and closes the
  selector before rendering its own page.
- Memory pressure may close the selector, but must not delete the saved Memo or
  agent exchange history.

## Required data model

The current `.sent.message.txt` and `.received.message.txt` files contain human
readable text but do not preserve enough structure to correlate a response
with a command. Implementation therefore adds an app-private exchange ledger:

```text
AgentExchange
  local_exchange_id
  agent
  sent_message_path
  sent_at
  delivery_request_id?
  delivery_mode
  response_history[]
    response_path
    received_at
    response_kind
  pending_summary_request_id?
```

The ledger contains no endpoint, secret, upgrade headers, transcript text, or
response text. Text remains in the existing atomic message files. The ledger
stores only app-private correlation metadata and file references.

For durability:

- update the ledger atomically after the corresponding message file is saved;
- keep `.sent.message.txt` and `.received.message.txt` as durable content
  sources;
- treat SQLite only as a rebuildable performance index;
- never export request IDs or ledger metadata to shared storage;
- never write agent names, request IDs, or private message text to logs;
- rebuild history from app-private atomic message records after restart;
- retain the latest sent-or-received message preview per configured agent while
  sorting and labeling rows by the latest received message and loading every
  indexed durable sent/received message in agent detail;
- append every correlated response update instead of replacing the previous
  response reference, and list named uncorrelated messages independently.

On startup and after a configuration save, the store indexes every existing
`.sent.message.txt` and `.received.message.txt` file with a complete configured
agent prefix. It also recovers the newest durable selector preview when
exchange metadata is missing. Imported commands have no historical request ID,
so recovery never fabricates response correlation.

Changing WebSocket configuration clears the in-memory selector and pending
summary association, but it does not clear durable agent history. The saved
agent-name list filters which recovered records are offered by the phone and G2
views for the newly configured server.

## Display ownership and concurrency

The display owner priority is:

1. active Memo;
2. agent history selector/detail interaction;
3. normal transcript and inbound-message status queue;
4. visual audio pulse.

The normal status owner also uses the full-height text page for `Queued:`,
`Sending:`, `Sent:`, `Saved:`, and `Received:` content. It restores the compact
visualizer only when the current FIFO item clears; the two-row visualizer text
slot is reserved for short gesture labels.

While the selector owns the display:

- normal statuses continue their durable work but cannot overwrite the page;
- title statuses, transcript-body updates, and terminal detail renders enter
  the coalesced display queue without blocking Gemma correction, WebSocket delivery, or
  acknowledged-message persistence;
- a corrected transcript bound to the selected agent reuses the ready socket
  and enters the ordinary bounded FIFO/busy retry path used by spoken agent
  routes; the selected detail waits for its own positive acknowledgement before
  changing from `Sending:` to `Sent:`;
- unrelated inbound events are persisted and deferred from the glasses;
- every BLE write remains high priority and individually time-bounded;
- dismiss sends the redundant private-text clear before restoring the audio
  visualizer;
- an unexpected disconnect retains selector or detail state for a bounded
  rerender after reconnect;
- configuration changes and app shutdown clear private selector state.

`GlassesStatusQueue` accepts an explicit display owner instead of treating
every pause as Memo. The selector does not reuse the queue's two-second
transient lifecycle because selection requires persistent,
gesture-controlled ownership.

## Implementation

1. `VoiceWebSocketClient` exposes typed outbound and inbound protocol results.
   The controller receives accepted delivery request IDs and inbound event
   metadata without logging private values.
2. The atomic `AgentExchangeStore` sits beside `WebSocketMessageStore`. It owns
   correlation metadata and rebuilds a bounded per-agent view.
3. The pure `G2AgentHistoryState` model owns selection wrapping, bounded
   conversation rendering, page state, and cancellation. Both selector and
   detail rendering use the same `G2TextLayout` utility for physical width,
   glyph measurement, row capacity, block packing, and overlapping pages.
4. Tap and swipe events route through that state before ordinary gesture
   display. Active Memo remains the first gate. While the selector is closed,
   a visible `Queued:` transcript consumes single tap before selector open:
   leading `Hey` changes the item to `Sending:` and prioritizes correction;
   anything else resolves to `Saved:`.
   Double tap retains its existing shortcut only while the selector is closed.
   Agent rows and newly opened details retain the ordinary speech path. A
   second tap in agent detail changes `>` to `<` on the Listen row, snapshots
   the title's configured agent, and starts a manually bounded transcript
   session for direct routing without a spoken wake word or name. Swipe up
   stops the mode, clears the unfinished speech overlay, restores the prior history page,
   and moves focus to the `< Agent` control. Tap there returns to the selector;
   swipe down returns to Listen. While the manual session is active, a down
   swipe pages the transcript directly. Tap-to-send
   retains its delivery
   state in the fixed control row while the body resumes pageable history.
   Active Listen Mode switches the VAD audio-chunk endpoint to one inactive
   second. Speech detected during that endpoint resets it. A completed endpoint
   queues its durable WAV in the persistent STT FIFO without ending the manual
   session. Each STT result extends and redraws the accumulated transcript, and
   the title status blinks while STT is pending. Preview Correction is always
   enabled and is not selectable. Each append automatically refreshes a
   serialized correction preview, and Send reuses the current preview without
   another LLM request. Selected-agent correction is inserted ahead of pending
   normal jobs while never interrupting an already-running Gemma inference.
5. Persistent selector and detail pages use the full 576×288 G2 text
   container. Multi-page details overlay one variable-height right-edge bitmap
   with a visible 4-pixel thumb inside a valid 20-pixel container. History uses
   a borderless surface with one stable four-pixel inset; the selector uses a
   fixed pointer gutter and adaptively windows complete one- or two-row entries
   while reserving one physical row below the selector.
   Agent details reserve two fixed control rows and seven content rows; Memo details
   reserve one title and eight content rows.
   All use high-priority bounded writes.
6. The latest saved Memo is read locally without routing it through WebSocket
   or the agent exchange store.
7. Selector rendering reads app-private atomic records and does not wait on a
   shared-folder scan or SQLite cache.

## Test plan

### Pure state tests

- opening always selects `[x]`;
- swipe up/down wraps across `[x]`, five agent options, and the final Memo
  option;
- every agent starts one `[Agent] content` row, may use one aligned continuation
  row, collapses carriage returns, newlines, and repeated whitespace before
  measurement, ellipsizes further pixel overflow, and leaves the selector
  below the nine-row native scrolling height and 2,000 UTF-8 bytes;
- agent rows never include an elapsed-time element, while their sort order
  still follows newest received-message activity;
- selected and unselected pointer gutters have equal measured width, including
  two spaces after `>`, so cursor movement never shifts row content;
- selector and detail rendering share the same calibrated width and row-layout
  utility;
- every agent detail exposes the exact two control rows plus seven content rows;
  Memo details expose eight content rows, and both repeat the prior page's final
  row first after a forward swipe;
- empty Memo and agent options never send;
- tapping an agent loads every indexed durable message and enters detail;
- sent messages and received updates render as
  `[HH:mm] Message` without agent or direction labels;
- missing responses leave the timestamped sent message intact without sending
  a request;
- a second tap in inactive agent detail activates Listen Mode;
- active Memo blocks selector open and double tap still finalizes Memo;
- a queued transcript consumes tap before selector open, with leading-`Hey`
  correction and immediate non-`Hey` save dispositions tested independently;
- selected agent rows and inactive agent details return no direct-speech target;
  a second tap enables the target, and an upward swipe exits before any later
  speech can inherit the target, clears its transient overlay, restores the
  prior pageable history body, and focuses the agent back control;
- agent details render the fixed title `   [Name] - Swipe to Navigate` and
  initially show ` >  • Listen Mode - Tap to start`; active Listen Mode changes
  only the second row to ` <  • Send transcript - Tap`. There is no
  Preview Correction row or toggle. The agent appears only
  in the title and is immutably snapshotted for the manual session. Transcript
  states never replace another newer session;
- selected-agent detail speech uses a one-second VAD-inactive audio-chunk
  endpoint; every completed STT chunk appends to the visible accumulator, later
  VAD speech remains in the same manual session, and no endpoint invokes
  delivery;
- transcription state remains internal while each result appends; the body
  contains only the raw or corrected transcript and never repeats `Listening`;
- automatic preview correction queues at most one correction at a time,
  coalesces a newer STT revision, renders a corrected prefix plus any raw tail,
  and keeps those states out of the fixed navigation title;
- explicit Listen Mode selection makes non-`Hey` live speech
  correction-eligible, while all other ambient speech remains wake-gated;
- `ladies changes` is corrected to context-supported `latest changes` before
  the selected-agent route receives it;
- the second tap on Send exits Listen Mode, acknowledges the final VAD flush,
  waits for all registered STT chunks, and reuses the current automatic preview
  without a second correction. Further taps while sending are inert, and page
  teardown waits for any active render before restoring the visualizer;
- changing selection after Listen Mode starts cannot change that session's
  target;
- removing the snapshotted agent from configuration prevents the send;
- selected-agent delivery reuses the ready WebSocket and enters the same
  bounded acknowledgement and busy-retry queue as a spoken `Hey <agent>`
  route;
- matching indexed responses refresh the open agent's first page without
  resetting its focused control or active listen/send lifecycle;

### Protocol and persistence tests

- only positive modern acknowledgement updates the latest agent command;
- busy retry preserves the final accepted request ID;
- selected-agent busy responses remain queued for bounded retry; rejection,
  timeout, and connection loss retain the message locally when delivery cannot
  be acknowledged;
- rejection and timeout retain the previous successful command;
- every matching progress/completion update appends to the correct exchange;
- unrelated and uncorrelated events remain unattached to an exchange but stay
  visible as independent received history for their named agent;
- G2 detail loading calls the same retained-message loader as the phone agent
  tab and filters to only the selected agent;
- configuration change clears live selection and pending timers;
- restart rebuilds message history from atomic app-private message files and
  exchange previews from app-private metadata;
- legacy fallback never claims durable correlation it cannot prove.

### Display concurrency tests

- selector ownership prevents transcript and unrelated inbound overwrite;
- Memo preempts selector;
- multi-page details render a proportional right-edge indicator without
  changing selector geometry;
- duplicate notifications and state callbacks coalesce to one page render and
  one thumb upload while that signature is queued, active, or already shown;
- rapid swipes retain only the latest pending page while one serialized BLE
  text/thumb update is active, instead of replaying every intermediate page;
- every full-page frame passes the render-safety guard before a BLE write;
  identical frames are suppressed, swipe changes may update only an existing
  compatible page in place, and a required replacement is deferred to the
  settled page-recovery path;
- dismiss clears private text before restoring the pulse;
- BLE timeout cannot stall later selector writes;
- disconnect/reconnect rerenders no more than one bounded private page.

### Physical-device acceptance

Use a fresh Android build number and a synthetic local fixture on a
representative phone:

1. send one acknowledged command to each of five synthetic agents and receive
   replies at distinguishable times;
2. connect the physical G2/R1 pair;
3. tap and verify `[x]` is selected first;
4. verify the newest replying agent is first, no row shows an elapsed-time
   element, and never-replied agents follow; then swipe through every agent and
   the final Memo option while checking the optional
   aligned continuation row, second-row ellipsis, stable horizontal alignment,
   the unused ninth physical row, and the borderless surface;
5. select an agent with more than five exchanges and multiple response updates,
   verify the G2 list exactly matches the phone agent tab in newest-message
   order, with every item shown as `[HH:mm] Message`, and verify that the
   right-edge indicator moves through every detail page,
   with the prior final row repeated first after each forward swipe, then tap to
   dismiss;
6. select an agent without a response and verify its timestamped sent message
   remains visible without any outbound request;
7. verify unrelated inbound events do not replace the open history page;
8. start an agent Listen Mode session, confirm there is no Preview Correction
   row, speak two phrases separated by a VAD endpoint, and verify the title
   advances through transcribing/queued/correcting/ready while retaining
   `Tap to send`;
9. verify the preview refreshes for the full aggregate, swipe down to page the
   transcript directly, then tap Send and verify delivery reuses that preview
   without a second correction request;
10. start Memo and confirm tap cannot open the selector while double tap still
   finalizes it;
11. disconnect/reconnect G2 during selection and verify bounded recovery;
12. confirm continuous capture has no gap and all sent/received files remain
    durable.

Raw screenshots, recordings, device logs, and protocol traces remain outside
the repository and are deleted or preserved only under the repository's
explicit privacy rules.

### Debug gesture simulation

A foregrounded debug APK accepts explicit ADB intents at the same
`WearableController` boundary used by a decoded R1 event. Gesture types are `0`
single tap, `1` swipe up, `2` swipe down, and `3` double tap:

```sh
adb -s <android-serial> shell am start \
  -n dev.opensourceglasses.even_g2_r1_poc/.MainActivity \
  -a dev.opensourceglasses.even_g2_r1_poc.SIMULATE_R1_GESTURE \
  --ei gesture_type 2
```

Four app-private selector fixtures exercise short rows, consecutive long rows,
mixed one- and two-line rows with normalized line breaks, and extreme ASCII
widths. Fixture text is synthetic, is not persisted, and is never logged:

```sh
adb -s <android-serial> shell am start \
  -n dev.opensourceglasses.even_g2_r1_poc/.MainActivity \
  -a dev.opensourceglasses.even_g2_r1_poc.SHOW_AGENT_SELECTOR_FIXTURE \
  --ei selector_fixture 1
```

The hooks validate each action and integer, report only gesture or fixture
metadata, and are disabled in non-debuggable builds. They exercise controller
state, serialized rendering, and live G2 writes. They do not qualify the
physical R1-to-G2 radio or firmware forwarding path, which remains a separate
manual check.

The sending-state fixture opens a synthetic agent detail already showing
`Sending - Wait`. It performs no capture, correction, persistence, or network
request, so repeated simulated taps can stress the live G2 page safely:

```sh
adb -s <android-serial> shell am start \
  -n dev.opensourceglasses.even_g2_r1_poc/.MainActivity \
  -a dev.opensourceglasses.even_g2_r1_poc.SHOW_AGENT_SENDING_FIXTURE
```

### Validation performed

On 2026-07-30, the checked-in Android validator ran on the representative
physical phone against an isolated loopback fixture with five synthetic agent
rows. It verified `[x]`-first selection, Memo selection and detail display,
Pike command persistence, the missing-response waiting page, one correlated
summary request, matching response replacement, and final dismissal. The
fixture did not connect to or send work to any configured agent session.

That historical run predates the retained timestamped message-list behavior
and is not evidence for the newer paging contract.

This deterministic phone-side run covers the protocol, persistence, and
gesture state used by the G2 controller. Final optical readability and physical
tap/swipe actuation on a paired G2/R1 remain manual checks because the test
harness cannot mechanically actuate the wearable.

On 2026-08-08, Android build 91 was installed on the representative physical
phone and the host-only Kokoro acoustic runner passed both a single phrase and
a 61.152-second continuous case. The long case remained one logical turn across
four STT chunks and three duration rollovers, with 0.213 WER, 100 median audio
frames per second, the 1,500 ms default endpoint, no capture failure, and no
unexpected disconnect. This validates the underlying G2/BLE/VAD/STT queue used
by both modes; it does not replace manual G2 tap/swipe acceptance for Preview
Correction because the harness cannot actuate the wearable controls.

## Acceptance criteria

- Tap opens the selector with `[x]` selected when no transcript is `Queued:`.
- Tap on `Queued:` changes a leading-`Hey` item to `Sending:` and prioritizes
  its correction job, or immediately saves any other transcript without
  opening the selector.
- Agent rows and inactive details retain ordinary wake/name routing. A second
  tap in agent detail changes the Listen arrow from `>` to `<`; speech beginning
  afterward sends its Gemma-corrected transcript to the agent shown once in the
  title without requiring `Hey` or the agent name. Swipe up stops Listen Mode
  and focuses `< Name`; tap returns to the selector, while swipe down returns
  to Listen and subsequent down swipes page.
- Agent details show the fixed title `   [Name] - Swipe to Navigate` and
  initially show ` >  • Listen Mode - Tap to start`. Active Listen Mode changes
  only the second row to ` <  • Send transcript - Tap` without a Preview
  Correction row. Swipe down pages the transcript directly. A tap on Send exits
  the mode and changes only that row to ` <  • Sending - Wait`. Repeated taps
  are ignored until the delivery completes. Stopping restores the exact prior
  history page so swipe paging resumes immediately.
- In detail mode, one uninterrupted second with VAD inactive finalizes one
  audio chunk, not the manual session. VAD activity during that second resets
  the chunk endpoint. Each completed STT result appends to and redraws only the
  transcript body; later speech continues the same session without a send. The
  title remains fixed while STT is pending. Every append refreshes one
  serialized automatic preview; Send waits for and reuses the current result
  without another correction request.
- `[x]` renders on one line; each agent and Memo uses one first row and at most
  one aligned continuation row inside a fixed-width pointer gutter. Carriage
  returns, newlines, and repeated whitespace collapse before measured wrapping;
  further pixel overflow is ellipsized. Moving `>` never shifts content, and
  adaptive windowing never splits an entry.
- Swipes select deterministically and wrap.
- Only acknowledged commands appear as sent.
- Every successfully indexed response for the open agent rebuilds page 1 from
  the complete durable message list immediately. Other-agent responses do not
  interrupt the selected detail.
- Selecting an agent shows the same newest-message-first retained list as the
  phone agent tab without issuing a network request. Every indexed sent and
  received message appears as `[HH:mm] Message` without an agent or direction
  label, including history recovered from durable files after an index loss.
- Every multi-page Memo or agent detail shows a right-edge page-position
  indicator that remains visible and tracks bounded swipe paging; one-page
  details do not allocate an image container. All agent pages contain seven
  body rows beneath two fixed lines. Memo pages contain eight body rows beneath one
  title.
  All repeat the prior page's final body row after a forward swipe.
- A missing response leaves the timestamped sent message visible; unrelated
  events do not become correlated responses.
- Tap on Send during `Listening` exits Listen Mode, flushes current audio, and
  waits for all snapshotted session chunks to finish STT. It sends the current
  automatically corrected aggregate without invoking correction again; a
  failed preview retains raw text and resolves without routing.
- Tap during `Sending:` is consumed without dismissing, rerendering, or
  starting another delivery. The page remains stable until delivery resolves.
- Memo and the prior double-tap behavior keep their documented priority.
- No selector operation blocks or weakens capture, storage, correction, message
  delivery, privacy, or BLE timeout boundaries.
