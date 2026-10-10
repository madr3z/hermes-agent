"""Client correlation survives the real queue and isolated turn paths without entering model history."""

import io
import json
import types
import threading

from hermes_state import SessionDB
from tui_gateway import server
from tui_gateway.compute_host import ComputeHost
from tests.tui_gateway.test_compute_host_turn_protocol import _session, _wait
from tests.tui_gateway.test_queued_prompt_persistence import _desktop_session, _busy


pytest_plugins = ["tests.tui_gateway.test_compute_host_turn_protocol"]


def test_distinct_queued_turns_complete_with_their_own_token(monkeypatch, tmp_path, turn_env):
    db = SessionDB(db_path=tmp_path / 'state.db')
    sid, key = _desktop_session(monkeypatch, db)
    session = server._sessions[sid]
    events, inputs = [], []
    changed = threading.Condition()

    def emit(event, sid, payload=None):
        with changed:
            events.append((event, payload))
            changed.notify_all()

    def wait_completions(count):
        with changed:
            assert changed.wait_for(
                lambda: sum(event == "message.complete" for event, _ in events) >= count, timeout=20)

    def run(prompt, **kwargs):
        inputs.append((prompt, kwargs))
        return {'final_response': 'done', 'messages': [
            {'role': 'user', 'content': prompt}, {'role': 'assistant', 'content': 'done'}]}

    session['agent'] = types.SimpleNamespace(session_id=key, run_conversation=run, clear_interrupt=lambda: None)
    monkeypatch.setattr(server, '_emit', emit)
    monkeypatch.setattr(server, '_wait_agent_for_prompt', lambda *args: None)
    monkeypatch.setattr(server, '_start_agent_build', lambda *args: None)
    monkeypatch.setattr(server, '_restart_completed_failed_agent_build', lambda *args: False)
    monkeypatch.setattr(server, '_session_uses_compute_host', lambda *args: False)

    def submit(token=None):
        params = {'session_id': sid, 'text': 'same task', 'queued': True}
        if token is not None:
            params['client_turn_id'] = token
        return server.handle_request({'id': 'submit', 'method': 'prompt.submit', 'params': params})

    try:
        _busy(session, 'same task')
        for token in ('voice-A', 'voice-B'):
            assert submit(token)['result'] == {'status': 'queued', 'client_turn_id': token}
        assert session['queued_prompt']['client_turn_id'] == 'voice-A'
        assert session['queued_prompts'][0]['client_turn_id'] == 'voice-B'
        session['running'] = False
        assert server._drain_queued_prompt('drain', sid, session)
        wait_completions(2)
        session['_run_thread'].join(timeout=20)
        assert submit()['result']['status'] == 'streaming'
        wait_completions(3)
        session['_run_thread'].join(timeout=20)
        completes = [payload for event, payload in events if event == 'message.complete']
        assert [payload.get('client_turn_id') for payload in completes] == ['voice-A', 'voice-B', None]
        assert len(inputs) == 3
        assert 'voice-A' not in repr(inputs) and 'voice-B' not in repr(inputs)
        assert all('client_turn_id' not in row for row in session['history'])
        assert 'voice-A' not in json.dumps(db.get_messages_as_conversation(key))
        for invalid in ('', 'x' * 201, 42):
            response = submit(invalid)
            assert response['error']['code'] == 4000
        assert len(inputs) == 3
    finally:
        server._sessions.pop(sid, None)
        db.close()


def test_compute_host_passes_correlation_to_completion_only(monkeypatch, turn_env):
    out = io.StringIO()
    host = ComputeHost(stdout=out, heartbeat_secs=0)
    inputs = []

    def run(prompt, **kwargs):
        inputs.append((prompt, kwargs))
        return {'final_response': 'done', 'messages': [
            {'role': 'user', 'content': prompt}, {'role': 'assistant', 'content': 'done'}]}

    session = _session(types.SimpleNamespace(
        session_id='s1-key', run_conversation=run, clear_interrupt=lambda: None))
    server._sessions['s1'] = session
    monkeypatch.setattr(server, '_get_compute_host_supervisor', lambda *args: types.SimpleNamespace(
        submit_turn=lambda frame, on_complete: host.handle_frame(frame)))
    try:
        ack = server._submit_prompt_to_compute_host('rpc', 's1', session, 'hello', client_turn_id='isolated-A')
        assert ack['result']['client_turn_id'] == 'isolated-A'
        _wait(out, lambda frame: frame['type'] == 'turn.end')
        frames = [json.loads(line) for line in out.getvalue().splitlines()]
        completes = [frame['message']['params']['payload'] for frame in frames
                     if frame['type'] == 'rpc' and frame['message']['params']['type'] == 'message.complete']
        assert [payload.get('client_turn_id') for payload in completes] == ['isolated-A']
        assert 'isolated-A' not in repr(inputs)
        assert all('client_turn_id' not in row for row in session['history'])
    finally:
        server._sessions.pop('s1', None)
        host.close()
