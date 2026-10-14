"""Saved speech reaches one bot's next input without changing the cached prefix."""
import json
from types import SimpleNamespace
from unittest.mock import patch

from hermes_state import SessionDB
from hermes_state_voice import append_voice_fragment
from tools.session_search_tool import session_search
from tests.agent.test_api_content_sidecar import _chat_requests, _user_messages, _text_resp


pytest_plugins = ('tests.agent.test_api_content_sidecar',)


def speak(db, sid, event, text, speaker='user', utterance=None, timestamp=100):
    with patch('hermes_state_voice.time.time', return_value=timestamp):
        return append_voice_fragment(db, sid, dict(call_id='call', event_id=event,
            utterance_id=utterance or event, speaker=speaker, text=text, start_ms=0, end_ms=10))


def canonical(db, sid='bot'):
    db.create_session(sid, 'desktop')
    db.set_session_title(sid, 'Bot Chat')
    db.set_session_hidden(sid, True)
    return sid


def note(db, sid='bot', content='Next question', cutoff=200):
    from agent.bot_chat_context import bot_chat_voice_context
    return bot_chat_voice_context(SimpleNamespace(_session_db=db, session_id=sid,
                                 _current_turn_timestamp=cutoff), content)


def test_typed_turn_replays_speech_once_after_restart_without_changing_prefix(wire_env):
    make_agent, handler, db, sid = wire_env
    canonical(db, sid)
    speak(db, sid, 'a', 'Remember the blue ', utterance='one')
    speak(db, sid, 'b', 'folder.', utterance='one')
    speak(db, sid, 'c', 'I will use that folder.', speaker='assistant')
    handler.response_queue = [_text_resp('Acknowledged'), _text_resp('Next answer')]
    make_agent().run_conversation(user_message='Continue our work')
    sent = _chat_requests(handler)[-1]
    current = _user_messages(sent)[-1]['content']
    assert 'Remember the blue folder.' in current
    assert current.index('user: Remember') < current.index('assistant: I will')
    rows = db.get_messages_as_conversation(sid)
    assert rows[0]['content'] == 'Continue our work'
    assert rows[0]['api_content'] == current
    assert '<voice-receipt>' not in rows[0]['content']
    make_agent().run_conversation(user_message='And the next item?', conversation_history=rows)
    second = _chat_requests(handler)[-1]
    assert second['messages'][:len(sent['messages'])] == sent['messages']
    assert 'Remember the blue folder.' not in _user_messages(second)[-1]['content']


def test_receipts_follow_only_verified_lineage_and_do_not_consume_future_or_unsent_speech(tmp_path):
    path = tmp_path / 'state.db'
    db = SessionDB(db_path=path)
    canonical(db)
    db.create_session('other', 'desktop')
    speak(db, 'bot', 'a', 'Blue ', utterance='one')
    speak(db, 'bot', 'b', 'folder.', utterance='one')
    speak(db, 'other', 'foreign', 'Foreign private speech')
    speak(db, 'bot', 'future', 'Future speech', timestamp=300)
    original = db.get_messages_as_conversation('bot')
    first = note(db)
    assert 'Blue folder.' in first and 'Foreign' not in first and 'Future' not in first
    assert note(db) == first  # An unpersisted/cancelled attempt consumes nothing.
    assert db.get_messages_as_conversation('bot') == original
    db.append_message('bot', 'user', first)
    assert note(db) == first  # Ordinary user text cannot forge a durable receipt.
    db.append_message('bot', 'user', 'Next question', api_content='Next question\n\n' + first)
    assert note(db) == ''
    speak(db, 'bot', 'c', ' Add a label.', utterance='one', timestamp=150)
    fresh = note(db)
    assert ' Add a label.' in fresh and 'Blue folder.' not in fresh
    db.append_message('bot', 'user', 'Another', api_content='Another\n\n' + fresh)
    db.end_session('bot', 'compression')
    db.create_session('tip', 'desktop', parent_session_id='bot')
    db.set_session_title('tip', 'Bot Chat')
    db.set_session_hidden('tip', True)
    db._write_sql("UPDATE messages SET active=0,compacted=1 WHERE session_id='bot'")
    db.close()
    reopened = SessionDB(db_path=path)
    assert note(reopened, 'tip') == ''
    assert 'Future speech' in note(reopened, 'tip', cutoff=400)
    reopened.end_session('tip', 'branched')
    reopened.create_session('fork', 'desktop', parent_session_id='tip')
    reopened.set_session_title('fork', 'Different')
    assert note(reopened, 'fork', cutoff=400) == ''
    assert json.loads(session_search(session_id='fork', db=reopened))['saved_speech'] == []
    reopened.close()


def test_delegated_context_is_acknowledged_and_older_speech_is_searchable_in_own_store(tmp_path):
    db = SessionDB(db_path=tmp_path / 'one.db')
    canonical(db)
    speak(db, 'bot', 'a', 'Travel plan is ', utterance='one')
    speak(db, 'bot', 'b', 'Oslo.', utterance='one')
    from tools.voice_live import voice_live_turn_note
    supplied = voice_live_turn_note('user: Travel plan is \nuser: Oslo.') + '\n\ncheck it'
    receipt = note(db, content=supplied)
    assert receipt and 'Travel plan is Oslo.' not in receipt
    db.append_message('bot', 'user', 'check it', api_content=supplied + '\n\n' + receipt)
    assert note(db) == ''
    match = json.loads(session_search(query='Travel plan', db=db, current_session_id='bot'))
    assert match['spoken_matches'][0]['content'] == 'Travel plan is Oslo.'
    read = json.loads(session_search(session_id='bot', db=db))
    assert read['saved_speech'][0]['display_kind'] == 'voice_live'
    other = SessionDB(db_path=tmp_path / 'two.db')
    canonical(other)
    assert not json.loads(session_search(query='Travel plan', db=other)).get('spoken_matches')
    assert note(other) == ''
    other.close()
    db.close()


def test_note_bound_keeps_complete_utterances_and_never_acknowledges_skipped_text(tmp_path):
    db = SessionDB(db_path=tmp_path / 'state.db')
    canonical(db)
    for index in range(40):
        speak(db, 'bot', str(index), 'word ', utterance='whole')
    first = note(db)
    assert ('word ' * 40) in first  # Many vendor deltas still form one utterance.
    speak(db, 'bot', 'large', 'x' * 6500, timestamp=150)
    assert note(db) == first  # Skipped text cannot move the receipt.
    assert len(first) <= 6000
    db.append_message('bot', 'user', 'Next question', api_content='Next question\n\n' + first)
    assert note(db) == ''
    read = json.loads(session_search(session_id='bot', db=db))
    assert any(row['content_truncated'] for row in read['saved_speech'])
    db.close()


def test_session_search_dispatch_recalls_complete_speech_in_the_owning_store(tmp_path):
    from tools.registry import registry

    db = SessionDB(db_path=tmp_path / 'state.db')
    canonical(db)
    speak(db, 'bot', 'a', 'Remember the blue ', utterance='one')
    speak(db, 'bot', 'b', 'folder.', utterance='one')
    found = json.loads(registry.dispatch('session_search', {'query': 'blue folder'},
                                        db=db, current_session_id='bot'))
    assert found['spoken_matches'][0]['content'] == 'Remember the blue folder.'
    read = json.loads(registry.dispatch('session_search', {'session_id': 'bot'}, db=db))
    assert read['saved_speech'][0]['content'] == 'Remember the blue folder.'
    assert read['saved_speech'][0]['display_kind'] == 'voice_live'
    db.close()


def test_search_joins_utterance_deltas_only_across_verified_compression(tmp_path):
    db = SessionDB(db_path=tmp_path / 'state.db')
    canonical(db)
    speak(db, 'bot', 'a', 'Remember the blue ', utterance='one')
    db.end_session('bot', 'compression')
    db.create_session('tip', 'desktop', parent_session_id='bot')
    speak(db, 'tip', 'b', 'folder.', utterance='one', timestamp=150)
    found = json.loads(session_search(query='blue folder', db=db))
    assert found['spoken_matches'][0]['content'] == 'Remember the blue folder.'
    db.end_session('tip', 'branched')
    db.create_session('fork', 'desktop', parent_session_id='tip')
    speak(db, 'fork', 'c', 'Private phrase', utterance='one', timestamp=160)
    assert not json.loads(session_search(query='folder.Private', db=db))['spoken_matches']
    assert json.loads(session_search(session_id='fork', db=db))['saved_speech'][0]['content'] == 'Private phrase'
    db.close()


def test_shorter_historical_utterance_is_not_receipted_as_a_substring(tmp_path):
    from tools.voice_live import voice_live_turn_note

    db = SessionDB(db_path=tmp_path / 'state.db')
    canonical(db)
    speak(db, 'bot', 'old', 'yes', utterance='old', timestamp=10)
    context = note(db, content=voice_live_turn_note('user: yes, book it'), cutoff=200)
    assert 'user: yes' in context
    assert 'yes, book it' not in context
    db.close()


def test_delegated_receipt_does_not_acknowledge_boilerplate_or_task_text(tmp_path):
    from tools.voice_live import voice_live_turn_note

    db = SessionDB(db_path=tmp_path / 'state.db')
    canonical(db)
    speak(db, 'bot', 'a', 'Do the work', utterance='one')
    speak(db, 'bot', 'b', 'Check tomorrow', utterance='two')
    supplied = voice_live_turn_note('user: An unrelated request') + '\n\nCheck tomorrow'
    context = note(db, content=supplied)
    assert 'user: Do the work' in context
    assert 'user: Check tomorrow' in context
    db.close()
