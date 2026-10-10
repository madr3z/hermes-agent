"""Spoken display persistence must never trigger or rewrite a model turn."""
import threading

import pytest

from hermes_state import SessionDB
from hermes_state_voice import append_voice_fragment, merge_voice_messages, voice_messages


def fragment(event='one', text='Hello', **changes):
    return dict(call_id='call', event_id=event, utterance_id='user-one', speaker='user',
                text=text, start_ms=0, end_ms=100, **changes)


def test_spoken_history_survives_reopen_retry_and_compression_without_model_changes(tmp_path):
    path = tmp_path / 'state.db'
    db = SessionDB(db_path=path)
    db.create_session('bot', 'desktop')
    db.set_session_title('bot', 'Bot Chat')
    db.append_message('bot', 'user', 'Existing cached prompt')
    original = db.get_messages_as_conversation('bot')
    first = append_voice_fragment(db, 'bot', fragment())
    assert append_voice_fragment(db, 'bot', fragment()) == first
    append_voice_fragment(db, 'bot', fragment('two', ' there'))
    with pytest.raises(ValueError):
        append_voice_fragment(db, 'bot', fragment(text='Conflicting replay'))
    assert db.get_messages_as_conversation('bot') == original
    db.end_session('bot', 'compression')
    db.create_session('tip', 'desktop', parent_session_id='bot')
    assert append_voice_fragment(db, 'tip', fragment())['text'] == 'Hello there'
    db.close()
    reopened = SessionDB(db_path=path)
    assert [m['text'] for m in voice_messages(reopened, 'tip')] == ['Hello there']
    assert reopened.get_messages_as_conversation('tip') == []
    assert merge_voice_messages(reopened, 'tip', [])[0]['display_kind'] == 'voice_live'
    reopened.close()


def test_rpc_requires_owner_transport_and_writes_only_the_session_profile(tmp_path, monkeypatch):
    from tui_gateway import server
    launch = tmp_path / 'launch'
    secondary = tmp_path / 'secondary'
    launch.mkdir(); secondary.mkdir()
    monkeypatch.setenv('HERMES_HOME', str(launch))
    monkeypatch.setattr('pathlib.Path.home', lambda: tmp_path)
    db = SessionDB(db_path=secondary / 'state.db')
    db.create_session('bot', 'desktop')
    db.set_session_title('bot', 'Bot Chat')
    db.close()
    class Transport:
        def write(self, frame):
            return True
    owner = Transport()
    session = dict(session_key='bot', profile_home=str(secondary), history=[],
                   history_lock=threading.Lock(), transport=owner, source='desktop')
    monkeypatch.setattr(server, '_sessions', {'runtime': session})
    calls = []
    monkeypatch.setattr(server, '_emit', lambda *args: calls.append(args))
    def invoke(transport=owner, **extra):
        return server.dispatch({'id': 1, 'method': 'voice.live.transcript.append',
                                'params': dict(session_id='runtime', **fragment(), **extra)}, transport=transport)
    result = invoke()
    assert result['result']['message']['text'] == 'Hello'
    assert invoke()['result'] == result['result']
    assert 'error' in invoke(Transport())
    assert 'error' in invoke(unexpected=True)
    assert session['history'] == []
    assert not session.get('running')
    assert calls[-1][0] == 'voice.live.transcript'
    reopened = SessionDB(db_path=secondary / 'state.db')
    assert voice_messages(reopened, 'bot') == [result['result']['message']]
    assert reopened.get_messages_as_conversation('bot') == []
    reopened.close()
    other = SessionDB(db_path=launch / 'state.db')
    assert voice_messages(other, 'bot') == []
    other.close()


def test_resume_display_includes_spoken_only_chat_without_feeding_the_agent(tmp_path):
    from tui_gateway import server
    db = SessionDB(db_path=tmp_path / 'state.db')
    db.create_session('bot', 'desktop')
    db.set_session_title('bot', 'Bot Chat')
    append_voice_fragment(db, 'bot', fragment())
    assert db.get_session('bot')['message_count'] == 1
    model, display = db.get_resume_conversations('bot')
    assert model == display == []
    from types import SimpleNamespace
    ctx = SimpleNamespace(omit_messages=False, profile_home=str(tmp_path), inline_images=False, db=db, target='bot')
    assert server._voice_resume_messages(ctx, display)[0]['text'] == 'Hello'
    db.close()


def test_warm_payload_and_deferred_hydration_include_spoken_only_history(tmp_path, monkeypatch):
    from tui_gateway import server
    db = SessionDB(db_path=tmp_path / 'state.db')
    db.create_session('bot', 'desktop')
    append_voice_fragment(db, 'bot', fragment())
    db.close()
    session = dict(session_key='bot', profile_home=str(tmp_path), history=[],
                   history_lock=threading.Lock(), source='desktop', created_at=1)
    monkeypatch.setattr(server, '_fallback_session_info', lambda session: {})
    monkeypatch.setattr(server, '_attach_todo_state', lambda payload, session: payload)
    monkeypatch.setattr(server, '_sessions', {'runtime': session})
    warm = server._live_session_payload('runtime', session)
    assert warm['messages'][0]['text'] == 'Hello'
    assert warm['message_count'] == 1
    deferred = server._live_session_payload('runtime', session, omit_messages=True)
    assert deferred['messages'] == []
    assert deferred['messages_omitted'] is True
    assert deferred['message_count'] == 1
    assert server._live_session_payload('runtime', session)['messages'] == warm['messages']
    assert session['history'] == []
