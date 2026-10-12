# GPT Live spoken transcript history

GPT Live input/output transcript deltas are committed to the owning profile's
state.db in voice_live_transcripts. They are display history, separate from the
model messages table. A speech-only call creates the ordinary stored chat first;
Bot Chat uses its existing canonical stored session. No transcript write starts a
model turn, changes an existing model message, or rebuilds a cached prompt.

## Wire contract

An authenticated, attached session transport calls voice.live.transcript.append
with its runtime session_id, call_id, event_id, utterance_id, speaker (user or
assistant), text, start_ms and end_ms. IDs are 1–200 characters; text is 1–16000.
Times are finite nonnegative milliseconds and end_ms cannot precede start_ms.
The optional profile follows the existing profile routing contract.

Append returns {message: TranscriptMessage}; voice.live.transcript.list returns
{messages: TranscriptMessage[]}. The voice.live.transcript event carries the
same full committed message snapshot. Every snapshot has display_kind=voice_live,
backend Unix-seconds timestamp, and display_metadata containing voice_message_id,
call_id, start_ms and end_ms. Stable voice_message_id is voice:<call>:<utterance>.
These display rows have no normal message row_id.

Clients concatenate transcript fragments in received order, opening a new
utterance on speaker change or a gap greater than 1500 ms. Retried event IDs are
idempotent across compression lineage; conflicting reuse is rejected. Transcript
time ranges come from the vendor, while the backend records receipt time for
interleaving with ordinary chat. Session deletion cascades to its speech records.

## Desktop recovery and display

The writer freezes the stored session and connection/profile owner when a call
starts. Its serialized outbox journals fragments before sending, then removes
them only after acknowledgment. Reconnect can resume that same stored session;
reload and browser online events retry remaining fragments. The outbox is keyed
by connection/profile/stored session and follows profile rename/deletion.
Persistence failures are surfaced. Browser storage is local transcript data and
is not an encrypted secret store.

Resume and REST history merge speech into the display projection without changing
model replay or ordinary message pagination. The renderer uses stable voice IDs
and zero normal-row span. Duplicate snapshots cannot shorten an utterance.
A delegated user prompt is hidden only after its spoken transcript is committed.
An exact spoken echo of an ordinary assistant answer shares the existing answer
bubble; a spoken paraphrase stays visible. Only received transcript events are
saved: submitting commentary to GPT Live is not evidence it was spoken or heard.

## Later model access

The next string user turn in the hidden canonical Bot Chat includes saved speech
as a bounded historical-data note. It selects at most 24 complete utterances and
keeps the whole note below 6,000 characters. It follows the verified compression
lineage in the owning profile database. Receipt timestamps exclude speech that
arrived after the turn started. Oversized utterances remain available through
session_search instead of being partially acknowledged.

The current turn's existing api_content sidecar stores the note and a receipt
with the last included fragment of each utterance. Its display text stays clean.
A restart or compression can reuse those receipts. Unpersisted attempts consume
nothing. Later deltas of an acknowledged utterance remain eligible. A delegated
GPT Live turn acknowledges speech already carried by its voice_context without
repeating it. Multimodal turns defer this automatic bridge to the next string
turn; session_search can still retrieve speech explicitly.

Existing session_search discovery includes bounded spoken_matches. Session read
includes saved_speech from the same verified lineage. Speech lookup uses literal
query text across transcript deltas; ordinary-message search still uses FTS5.
Speech markers are separate from ordinary message anchors. Search remains scoped
to the current profile unless the caller explicitly selects another profile.

Starting a new GPT Live call keeps the existing bounded history seeding, including
visible speech. Transcript persistence adds no model call and does not alter the
live delegation mechanism or Codex provider selection.

## Acceptance boundary

Automated checks exercise real SQLite reopening/compression, profile/transport
ownership, REST/resume display projection, stable replay, retries and local outbox
recovery. Live audio interruption, actual microphone/speaker use, remote reconnect
and iPhone integration still require runtime acceptance against this backend.
No pilot deployment is part of this change.

## Local validation for this change

- Prescribed backend runner: 6 tests pass across
  tests/tui_gateway/test_voice_live_transcripts.py,
  tests/hermes_cli/test_web_voice_transcript_history.py and
  tests/tui_gateway/contracts/test_generated.py.
  Command: HERMES_PYTHON="$PWD/.venv/bin/python" scripts/run_tests.sh -j 1
  followed by those three paths.
- Red-on-base: the REST test fails against the original sessions.py handler,
  returning only Existing text instead of Existing text plus Received speech.
  Restoring the handler makes the same test pass. The final proof terminated
  only the stalled optional compileall prewarm (the runner explicitly tolerates
  its failure); all actual tests ran. An earlier full successful run included
  the prewarm.
- Desktop: 13 tests pass across voice-live-transcript.test.ts,
  voice-transcript-outbox.test.ts, use-message-stream/voice-live-transcript.test.tsx,
  use-voice-live-conversation.test.ts and use-composer-voice.test.tsx, using the
  existing Vitest configuration with --pool forks --maxWorkers 1 --no-isolate.
  Thread workers timed out before tests; the reused fork ran successfully.
- Renderer tsc -p . --noEmit --incremental false passed.
- Changed-file ESLint passed; final code-health checks use
  .venv/bin/python scripts/check --only health.
- Full .venv/bin/python scripts/check is not a final green gate: its initial
  run passed 10 checks and identified code-health findings subsequently fixed;
  a full rerun timed out after 900 seconds in unchanged check_bash_shebangs.py.
  No claim of full CI, packaged desktop build, deployment or live acceptance.

## Independent review follow-up

The review follow-up makes ordinary-row pagination use pagination.returned, so a
repeated speech overlay neither skips ordinary rows nor arms endless backfill for
a speech-only conversation. Stable speech IDs deduplicate the repeated overlay.
Model-turn completion/interim/error boundaries and assistant candidates exclude
display-only speech. Warm resume and session.activate merge the same speech
projection, and deferred hydration retains a nonzero stored count for speech-only
sessions.

Validation after these changes: the prescribed Python runner passes 7 tests,
including warm/deferred hydration; its optional precompile also completed with
PYTHON_CPU_COUNT=1. Renderer typechecking, changed-file ESLint and code health pass.
The focused Desktop review set covers transcript-voice-pagination.test.ts,
transcript-tail.test.ts, use-message-stream/voice-live-transcript.test.tsx and
completion-boundaries.test.tsx. No live-acceptance or deployment claim is added.
