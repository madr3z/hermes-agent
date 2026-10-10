"""Already-accepted voice tasks settle even when dispatch or model preparation refuses them."""

import threading
from types import SimpleNamespace

import pytest

from hermes_state import SessionDB
from tui_gateway import server
from tui_gateway.turn_marker import read_turn_marker, record_turn_start
from tests.tui_gateway.test_queued_prompt_persistence import _desktop_session, _busy

pytest_plugins = ["tests.tui_gateway.test_compute_host_turn_protocol"]


@pytest.mark.parametrize('failure', ['compute-error', 'compute-exception', 'ownership', 'context'])
def test_accepted_correlated_queue_refusal_completes_once(monkeypatch, tmp_path, turn_env, failure):
    db = SessionDB(db_path=tmp_path / 'state.db')
    sid, key = _desktop_session(monkeypatch, db)
    session = server._sessions[sid]
    events, calls = [], []
    session['agent'] = SimpleNamespace(
        session_id=key, model='test', clear_interrupt=lambda: None,
        run_conversation=lambda *a, **k: calls.append(a))
    monkeypatch.setattr(server, '_emit', lambda event, sid, payload=None: events.append((event, payload)))
    monkeypatch.setattr(server, '_session_uses_compute_host', lambda *args: failure.startswith('compute'))
    try:
        _busy(session, 'old task')
        ack = server.handle_request({'id': 'voice', 'method': 'prompt.submit', 'params': {
            'session_id': sid, 'text': '@blocked', 'queued': True, 'client_turn_id': 'voice-B'}})
        assert ack['result'] == {'status': 'queued', 'client_turn_id': 'voice-B'}
        if failure.startswith('compute'):
            def submit(*args, **kwargs):
                if failure == 'compute-exception':
                    raise RuntimeError('dispatch refused')
                return server._err('voice', 5019, 'dispatch refused')
            monkeypatch.setattr(server, '_submit_prompt_to_compute_host', submit)
        elif failure == 'ownership':
            record_turn_start(server._session_home(session), key, 'active owner task')
            monkeypatch.setattr(server, '_ensure_active_session_slot', lambda *a: 'owner refused')
        else:
            monkeypatch.setattr('agent.context_references.preprocess_context_references',
                                lambda *a, **k: SimpleNamespace(blocked=True, warnings=['context refused']))
            monkeypatch.setattr('agent.model_metadata.get_model_context_length', lambda *a, **k: 10000)
        session['running'] = False
        server._clear_inflight_turn(session)
        assert server._drain_queued_prompt('voice', sid, session)
        worker = session.get('_run_thread')
        if isinstance(worker, threading.Thread):
            worker.join(timeout=20)
            assert not worker.is_alive()
        completes = [payload for event, payload in events if event == 'message.complete']
        assert len(completes) == 1
        assert completes[0]['status'] == 'error'
        assert completes[0]['client_turn_id'] == 'voice-B'
        assert not calls
        if failure == 'ownership':
            assert read_turn_marker(server._session_home(session), key)['prompt'] == 'active owner task'
    finally:
        server._sessions.pop(sid, None)
        db.close()
