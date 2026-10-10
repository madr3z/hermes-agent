"""The REST path used by desktop reload includes speech without altering model replay."""
import asyncio

from hermes_state import SessionDB
from hermes_state_voice import append_voice_fragment


def test_rest_transcript_includes_spoken_rows_and_preserves_normal_pagination(tmp_path, monkeypatch):
    from hermes_cli.web_routers import sessions
    db = SessionDB(db_path=tmp_path / 'state.db')
    db.create_session('bot', 'desktop')
    db.set_session_title('bot', 'Bot Chat')
    db.append_message('bot', 'user', 'Existing text', timestamp=1)
    append_voice_fragment(db, 'bot', dict(call_id='call', event_id='event', utterance_id='1',
        speaker='assistant', text='Received speech', start_ms=0, end_ms=100))
    monkeypatch.setattr(sessions, '_with_db', lambda profile, fn, **kwargs: fn(db))
    monkeypatch.setattr(sessions, '_history_profile_home', lambda profile: tmp_path)
    result = asyncio.run(sessions.get_session_messages('bot', profile=None, limit=None, offset=0,
        order=None, include_compacted=True, inline_images=False))
    assert [m.get('text', m.get('content')) for m in result['messages']] == ['Existing text', 'Received speech']
    assert result['pagination']['returned'] == 1
    assert db.get_messages_as_conversation('bot')[0]['content'] == 'Existing text'
    assert len(db.get_messages_as_conversation('bot')) == 1
    db.close()
