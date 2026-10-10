"""Durable spoken display history. Never inserted into the agent's messages table.

The normal transcript may be rewritten/compacted while a full-duplex call is speaking.
A separate table in the SAME profile state.db lets those writes coexist without touching
model context, turn leases, or cached prefixes. Session deletion cascades to speech.
"""
from __future__ import annotations

import time

_SCHEMA = """CREATE TABLE IF NOT EXISTS voice_live_transcripts (
    id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    call_id TEXT NOT NULL, event_id TEXT NOT NULL, utterance_id TEXT NOT NULL,
    speaker TEXT NOT NULL, text TEXT NOT NULL,
    start_ms REAL NOT NULL, end_ms REAL NOT NULL,
    timestamp REAL NOT NULL,
    UNIQUE(session_id, call_id, event_id)
)"""


def _rows(db, session_id, call_id=None, utterance_id=None):
    if not db._read_one("SELECT 1 FROM sqlite_master WHERE name = 'voice_live_transcripts'"):
        return []
    ids = db._resume_lineage_ids(session_id)
    where = f"session_id IN ({','.join('?' for _ in ids)})"
    values = list(ids)
    if call_id is not None:
        where += " AND call_id = ? AND utterance_id = ?"
        values.extend((call_id, utterance_id))
    return db._read_all(f"SELECT * FROM voice_live_transcripts WHERE {where} ORDER BY id", values)


def voice_messages(db, session_id, call_id=None, utterance_id=None):
    """Wire display rows, with stable ids across retries, runtime reattach and compression."""
    messages = {}
    for row in _rows(db, session_id, call_id, utterance_id):
        key = f"voice:{row['call_id']}:{row['utterance_id']}"
        if key not in messages:
            messages[key] = {
                "role": row["speaker"], "text": "", "timestamp": row["timestamp"],
                "display_kind": "voice_live",
                "display_metadata": {"voice_message_id": key, "call_id": row["call_id"],
                                     "start_ms": row["start_ms"], "end_ms": row["end_ms"]},
            }
        message = messages[key]
        message["text"] += row["text"]
        message["display_metadata"]["end_ms"] = row["end_ms"]
    return list(messages.values())


def append_voice_fragment(db, session_id, fragment):
    """A retry is a no-op; conflicting re-use of a vendor event id is rejected."""
    import math
    if not all(math.isfinite(fragment[k]) for k in ('start_ms', 'end_ms')) or fragment['end_ms'] < fragment['start_ms']:
        raise ValueError("Invalid transcript time range")

    def persist(conn):
        conn.execute(_SCHEMA)
        conn.execute("CREATE INDEX IF NOT EXISTS voice_live_utterance ON voice_live_transcripts(session_id, call_id, utterance_id)")
        existing = conn.execute(
            "SELECT * FROM voice_live_transcripts WHERE call_id = ? AND event_id = ? "
            "AND session_id IN (" + ','.join('?' for _ in lineage) + ')',
            (fragment['call_id'], fragment['event_id'], *lineage)).fetchone()
        if existing is not None:
            if any(existing[k] != fragment[k] for k in fields):
                raise ValueError("Transcript event id was already used for different speech")
            return
        prior = conn.execute(
            "SELECT speaker FROM voice_live_transcripts WHERE call_id = ? AND utterance_id = ? "
            "AND session_id IN (" + ','.join('?' for _ in lineage) + ") LIMIT 1",
            (fragment['call_id'], fragment['utterance_id'], *lineage)).fetchone()
        if prior is not None and prior['speaker'] != fragment['speaker']:
            raise ValueError("A transcript utterance cannot change speaker")
        conn.execute(
            "INSERT INTO voice_live_transcripts (session_id, " + ','.join(fields) + ", timestamp) "
            "VALUES (" + ','.join('?' for _ in range(len(fields) + 2)) + ')',
            (session_id, *(fragment[k] for k in fields), time.time()))
        # A spoken-only chat has display history; desktop must not mistake it for an empty draft.
        conn.execute("UPDATE sessions SET message_count = message_count + ?, last_activity_at = ? WHERE id = ?",
                     (int(prior is None), time.time(), session_id))
    fields = ('call_id', 'event_id', 'utterance_id', 'speaker', 'text', 'start_ms', 'end_ms')
    lineage = db._resume_lineage_ids(session_id)
    db._execute_write(persist)
    key = f"voice:{fragment['call_id']}:{fragment['utterance_id']}"
    return next(m for m in voice_messages(db, session_id, fragment['call_id'], fragment['utterance_id'])
                if m['display_metadata']['voice_message_id'] == key)


def merge_voice_messages(db, session_id, messages):
    """Merge display projections only, preserving the model transcript's own ordering."""
    return interleave_voice_messages(messages, voice_messages(db, session_id))


def interleave_voice_messages(messages, spoken):
    speech = iter(spoken)
    pending = next(speech, None)
    result = []
    for message in messages:
        while pending is not None and pending['timestamp'] <= (message.get('timestamp') or float('inf')):
            result.append(pending)
            pending = next(speech, None)
        result.append(message)
    if pending is not None:
        result.append(pending)
    result.extend(speech)
    return result
