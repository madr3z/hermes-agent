"""Bounded saved-speech results on the existing scoped session-search surface."""
from hermes_state_voice import recall_voice_utterances


def spoken_results(db, *, session_id=None, query=None, limit=10, roles=None, after=None, before=None,
                   excluded_roots=(), resolve_lineage=None, exclude_sources=()):
    rows = recall_voice_utterances(db, session_id, query=query, limit=limit, roles=roles,
                                  after=after, before=before, exclude_sources=exclude_sources)
    results = []
    for row in rows:
        if excluded_roots and (row['session_id'] in excluded_roots
                              or resolve_lineage(db, row['session_id']) in excluded_roots):
            continue
        results.append({**row, 'content': row['content'][:2000],
                        'content_truncated': row['content_chars'] > 2000})
    return results
