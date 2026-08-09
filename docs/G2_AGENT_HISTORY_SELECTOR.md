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

The selector starts every agent option as `Agent - content` and lets that
combined text flow into at most one continuation row. Opening the option loads
every exchange retained in the bounded agent ledger for only that agent. The
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

Every agent occupies one or two rendered lines. Newlines and repeated
whitespace in private content are collapsed. The first line always starts
`Agent - content`; only overflow continues on the second line with one extra
leading space after the pointer gutter, and longer text is ellipsized there.
`[x] - Swipe to Select` remains a fixed one-line header. There is no page
counter. Every line reserves a fixed
20-pixel pointer gutter, so replacing the blank gutter with `>` cannot move or
rewrap its content. A representative short selector
is:

```text
 > [x] - Swipe to Select
    Agent One - latest sent command
    Agent Two - No messages
    Agent Three - latest sent command
    Agent Four - No messages
    Agent Five - latest sent command
    Memo - latest saved memo
```

When long previews overflow, indivisible one- or two-row entries fill the eight
rows beneath the fixed header:

```text
 > [x] - Swipe to Select
    Agent One - latest sent command that continues
     on the second row…
    Agent Two - another command that continues on
     its second row…
…
```

The viewport keeps the selected complete entry block visible. While the next
one- or two-row entry already fits beneath the fixed header, a swipe moves only
the `>` cursor and the content remains stationary. When the next selected block
reaches the final visible position and its following block is hidden, the
viewport removes the minimum number of whole blocks from the top to reveal that
following block. For example, selecting `Brock` scrolls `Flux` off and exposes
`Memo` without requiring another swipe. Upward swipes behave symmetrically by
revealing a hidden preceding block when the cursor reaches the first visible
entry. The fixed header never moves and entries are never split across viewport
boundaries. Once the final entry is already visible, such as `Memo` beneath
`Brock`, the viewport remains fixed and the next swipe moves only the cursor.

The marker is the only selection indicator, so the layout remains grayscale
and does not rely on color. Wrapping uses G2 pixel advances instead of a fixed
rune budget. The complete nine-row page remains bounded to 2,048 characters.

History rebuilds the active Hub surface as a dedicated borderless 576x288 text
page with a four-pixel firmware inset. The selector and every detail-page
rebuild reuse that inset, so a physical swipe cannot move the first glyph at
the left display edge. Host layout uses one shared calibrated wrapping budget.
Standalone glyph advances overestimate the physically observed firmware width,
so the utility reserves an 18-pixel right-side safety budget and adds a 50-unit
calibration. Selector content receives a separate 20-pixel pointer gutter and
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
   [Agent One]
> • Listen Mode - Tap to start
[14:33] <correlated completion>
[14:32] <first correlated progress update>
[14:31] <most recent command>
[09:08] <previous command>
```

Commands and responses may wrap because this is a detail view, not a selector
row. An agent detail reserves two fixed rows and seven message rows. Opening it
does not enable speech targeting. A second tap changes the Listen row's active
arrow from `>` to `<` without shifting the title; only then does speech directly
target the agent named once in the title. Speech changes that row to
`< • Listening - Tap to send`. Swipe up stops Listen Mode and moves the active
`<` control to the agent title. Tapping that title returns to the selector;
swipe down returns focus to Listen Mode, and another down swipe advances a
page. While the title owns focus, another up swipe returns one page. A normal
stop clears the transient speech overlay and restores the exact
history page that was visible when Listen Mode started. The first VAD endpoint,
or an earlier tap, closes the one-utterance capture before correction begins,
so a later VAD start cannot replace the in-flight display owner. The detail
changes to `Sending`, shows the raw transcript as soon as STT completes, and
returns to newest-first durable history after acknowledgement.
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
message by timestamp, regardless of sent or received direction. Detail history
keeps every indexed durable message and never truncates to that preview bound.

Every detail page begins with `[ Memo · Tap to dismiss ]` or the two agent rows
`   [<name>]` and `> • Listen Mode - Tap to start`. Conversation rows use
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
Selector pages do not create the image container.

### Empty Memo or agent row

Memo is always present:

```text
Memo - No saved memo
```

An agent with no positively acknowledged command is also retained:

```text
Agent Two - No messages
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
| Tap active Listen Mode before speech | Exit Listen Mode without sending and restore the prior history page |
| Swipe up while the Listen row owns focus | Stop Listen Mode if active, restore history, and move `<` to the agent title |
| Tap while `< Agent` owns focus | Return to the selector without closing all history |
| Swipe down while the agent title owns focus | Move focus back to the Listen row |
| Swipe down while the Listen row owns focus | Show the next message page |
| Swipe up while the agent title owns focus | Show the previous message page |
| Swipe up/down in Memo detail | Show the previous/next Memo page |
| Tap during `Listening` | Exit Listen Mode, restore pageable history, and finalize only the current snapshotted speech for correction/send |
| Tap during `Sending:` | Dismiss the detail immediately; that delivery continues, but new speech is no longer targeted |
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
                      ├─ tap before speech ─► Listen Mode inactive
                      └─ speech ─► direct selected-agent route
                                      └─ tap ─► exit mode + finish speech
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

- The Memo option starts `Memo - content` and may use one continuation row.
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
  loading every indexed durable sent/received message in agent detail;
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
- `Listening…`, `Sending:`, and terminal detail renders enter the coalesced
  display queue without blocking Gemma correction, WebSocket delivery, or
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
   second tap in agent detail changes `>` to `<` on the Listen row; only a
   VAD speech start after that selection snapshots the title's configured agent
   for direct routing without a spoken wake word or name. Swipe up stops the
   mode, clears the unfinished speech overlay, restores the prior history page,
   and moves focus to the `< Agent` control. Tap there returns to the selector;
   swipe down returns to Listen, then further down swipes page. Tap-to-send
   retains its delivery
   state in the fixed control row while the body resumes pageable history.
   Active Listen Mode switches the VAD endpoint to one
   inactive second before STT. Speech
   detected during that endpoint resets it and continues the same audio turn;
   intermediate STT chunks only extend the logical transcript; the final
   accumulated turn is corrected and sent once. Explicitly selected
   correction is inserted ahead of pending normal jobs while never interrupting
   an already-running Gemma inference.
5. Persistent selector and detail pages use the full 576×288 G2 text
   container. Multi-page details overlay one variable-height right-edge bitmap
   with a visible 4-pixel thumb inside a valid 20-pixel container. History uses
   a borderless surface with one stable four-pixel inset; selector pages use a
   fixed pointer gutter and adaptively pack up to nine visible rows. Agent
   details reserve two fixed control rows and seven content rows; Memo details
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
- every agent starts `Agent - content`, uses at most one continuation row,
  keeps the selected option visible across page transitions, and leaves each
  page under 2,048 characters;
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
- active Memo blocks selector open and double tap still finalizes Memo.
- a queued transcript consumes tap before selector open, with leading-`Hey`
  correction and immediate non-`Hey` save dispositions tested independently;
- selected agent rows and inactive agent details return no direct-speech target;
  a second tap enables the target, and an upward swipe exits before any later
  speech can inherit the target, clears its transient overlay, restores the
  prior pageable history body, and focuses the agent back control;
- inactive agent details render `   [Name]` and
  `> • Listen Mode - Tap to start`; active Listen Mode renders
  `< • Listen Mode - Tap to stop`. The agent appears only
  in the title and is immutably snapshotted for the speech segment. Transcript
  states never replace another newer segment;
- selected-agent detail speech uses a one-second VAD-inactive endpoint, resumed
  VAD keeps the same turn open, and intermediate STT chunks remain collection-
  only until the finalized accumulated turn reaches correction;
- explicit Listen Mode selection makes non-`Hey` live speech
  correction-eligible, while all other ambient speech remains wake-gated;
- `ladies changes` is corrected to context-supported `latest changes` before
  the selected-agent route receives it;
- tap finalizes listening and exits Listen Mode without awaiting correction,
  restores the prior pageable history behind the sending control, or dismisses
  a sending detail while delivery continues independently;
- changing selection after speech starts cannot change that segment's target;
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
- dismiss clears private text before restoring the pulse;
- BLE timeout cannot stall later selector writes;
- disconnect/reconnect rerenders no more than one bounded private page.

### Physical-device acceptance

Use a fresh Android build number and a synthetic local fixture on a
representative phone:

1. send one acknowledged command to each of five synthetic agents;
2. connect the physical G2/R1 pair;
3. tap and verify `[x]` is selected first;
4. swipe through every agent and the final Memo option, checking the
   `Agent - content` first row, optional continuation row, borderless surface,
   and adaptive selector page transition;
5. select an agent with more than five exchanges and multiple response updates,
   verify the G2 list exactly matches the phone agent tab in newest-message
   order, with every item shown as `[HH:mm] Message`, and verify that the
   right-edge indicator moves through every detail page,
   with the prior final row repeated first after each forward swipe, then tap to
   dismiss;
6. select an agent without a response and verify its timestamped sent message
   remains visible without any outbound request;
7. verify unrelated inbound events do not replace the open history page;
8. start Memo and confirm tap cannot open the selector while double tap still
   finalizes it;
9. disconnect/reconnect G2 during selection and verify bounded recovery;
10. confirm continuous capture has no gap and all sent/received files remain
    durable.

Raw screenshots, recordings, device logs, and protocol traces remain outside
the repository and are deleted or preserved only under the repository's
explicit privacy rules.

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
- Inactive agent details show `   [Name]` and
  `> • Listen Mode - Tap to start`. Active Listen Mode shows
  `< • Listen Mode - Tap to stop`. Speech shows
  `< • Listening - Tap to send`; tap exits the mode and shows
  `< • Sending - Tap to dismiss`, followed by acknowledged
  `Sent` or fallback `Saved` in the fixed control row. Stopping restores the
  exact prior history page so swipe paging resumes immediately.
- In detail mode, one uninterrupted second with VAD inactive finalizes the
  speech turn. VAD activity during that second resets the endpoint and appends
  audio to the same turn. Bounded STT chunks can be processed before that point
  without creating a send. Once the endpoint fires, Listen Mode stops accepting
  selected-agent audio, the complete accumulated STT text replaces `Listening`,
  and correction plus the single send happen afterward.
- `[x]` renders as one line; each agent and Memo start `Agent - content` and
  flow into at most one bounded continuation line inside a fixed-width pointer
  gutter. The continuation has one additional leading space, with adaptive
  paging only when all entries cannot fit in the nine-row viewport.
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
  details do not allocate an image container. Agent pages contain seven body
  rows beneath two controls; Memo pages contain eight body rows beneath one
  title. Both repeat the prior page's final body row after a forward swipe.
- A missing response leaves the timestamped sent message visible; unrelated
  events do not become correlated responses.
- Tap during `Listening` exits Listen Mode, restores pageable message history,
  and immediately finishes only that snapshotted speech for correction/send.
- Tap during `Sending:` immediately dismisses the detail without cancelling or
  awaiting that delivery. Speech beginning after dismissal is not forwarded to
  the formerly selected agent.
- Memo and the prior double-tap behavior keep their documented priority.
- No selector operation blocks or weakens capture, storage, correction, message
  delivery, privacy, or BLE timeout boundaries.
