# Hey Memo voice notes

Work Bench has a local `Hey Memo` agent that turns successive dictated
utterances into one coherent on-device note. Memo input is downstream of
durable raw transcription and is never sent to the Voice WebSocket.

```text
G2 audio → journal → VAD → raw transcript → Gemma correction
                                      │              │
                                      └──── segment ─┘
                                                │
                         leading "Hey Memo" or active memo owner
                                                │
                                   durable memo source record
                                                │
                         Gemma memo revision in isolated process
                                                │
                         atomic memo JSON + TXT / Conversation UI
                                                │
                              bounded live projection on G2
```

## Invocation correction

An exact leading `Hey Memo` in raw STT activates the local agent immediately.
`Hey Memo` is also included in Gemma's bounded correction vocabulary so a
plausible leading acoustic variant can be restored before routing. The prompt
requires a leading invocation and memo-taking context. Corrected activation
also checks the durable raw transcript for both `Hey` and exact or explicitly
supported memo-like acoustic evidence such as `me mo` or `mimo`; a standalone
`Hey` cannot be expanded into the wake phrase. Ordinary prose such as `I wrote
a memo yesterday` must not activate the agent.

Words following the invocation become the first source utterance. While memo
mode is active, every newly started live VAD segment belongs to that memo before
WebSocket matching. Raw and corrected transcript files remain independently
durable.

Correction can finish after later utterances have already reached raw STT. To
avoid losing those turns, the memo service keeps at most 32 recent segment
states for one minute in memory only. When a corrected invocation activates,
it claims the later buffered segments in order and waits for any unfinished raw
turn. The backlog is never written into a memo unless correction validates the
leading invocation.

## Revisions and storage

Memo records live under the application-support directory:

```text
workbench/memos/
├── <memo-id>.memo.json
└── <memo-id>.memo.txt
```

The JSON record retains ordered source utterances, the current generated note,
revision number, timestamps, status, and a metadata-only error code. Every
update uses a partial file followed by atomic rename. The text file is a
readable derivative of the same current note.

Gemma receives the prior committed note plus the ordered source utterances. Its
separate memo prompt requires a short title, concise paragraphs or bullets,
preservation of concrete facts and uncertainty, and no invented content.
Requests use the same isolated, single-worker LiteRT-LM process as transcript
correction but a distinct `memo_revision` task. New input arriving during a
revision is coalesced into the next revision; a stale response cannot finalize
the session.

If Gemma is missing, times out, returns invalid output, or its process stops,
the ordered dictated text remains the fallback note. Capture, VAD, STT, raw
transcript access, and memo finalization remain available.

## Silence and explicit finish

The normal VAD turn closes after VAD remains inactive for 1.5 seconds (about
two seconds of acoustic silence including Silero qualification). Memo mode
keeps the outer session open for exactly five seconds of total silence:

```text
2.00 s nominal VAD turn boundary + 3.00 s memo continuation window = 5.00 s
```

New `speech_started` activity cancels the continuation timer. At five seconds,
the memo stops accepting unrelated new turns, waits for the already claimed
last segment and memo revision with a bounded watchdog, then saves the note.

During memo mode, the G2 page shows:

```text
[ Double Tap to finish ]
<Listening / Updating / Finalizing>

<current memo note>
```

A live note is host-paginated into seven body rows beneath the fixed action and
status rows. The newest page remains visible as revisions arrive. Swipe down
advances, swipe up returns, and the first/last page boundaries do not wrap.
Each multi-page draft shows `[ current/total · Swipe to scroll ]` on its final
row. These gestures change only the local G2 projection and never route memo
text to the Voice WebSocket.

A typed double tap is consumed before the normal gesture/audio behavior,
flushes any active VAD segment, and begins finalization. Memo display ownership
pauses normal transcript, inbound-message, gesture-label, and visual pulse
writes without stopping continuous LC3 capture. The phone retains the complete
note; the glasses projection is sanitized, host-paginated, and bounded to 4096
characters.

## History, restart, and privacy

The **Conversation** tab combines voice memos with optional speaker-labeled
turns. A live memo shows `Listening`, `Updating`, or `Finalizing`; a completed
memo shows `Saved`. Memo history does not require speaker analysis or a shared
folder.

An app restart restores an unfinished memo as `Interrupted` but never silently
resumes microphone ownership. Late corrected results for a completed memo
segment remain locally consumed and cannot restart the memo or route to an
agent.

Logs contain only state, provider, revision, counts, character lengths, and
timing. They never contain memo or transcript text.

## Validation

Automated coverage includes invocation parsing, standalone-`Hey` rejection,
corrected invocation recovery, ordinary-prose rejection, iterative revisions,
five-second timing, resumed speech, last-segment finalization, atomic restart
recovery, display ownership, the G2 action header, and phone-sized Conversation
UI.

Physical validation retains the existing Kokoro transport/VAD/STT contract and
adds fixed synthetic cases for `Hey Memo`, corrected acoustic variants,
sub-five-second continuation, and the five-second boundary. Validate the
physical R1/G2 double-tap gesture separately when an operator can actuate the
ring; automated coverage verifies the same finalization entry point. Raw
screenshots and physical evidence remain outside the repository.
