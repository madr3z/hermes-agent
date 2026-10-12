"""Only an actual tool call in the owning live voice turn can request hang-up."""
import threading

import pytest

from tui_gateway import server


class Transport:
    def __init__(self):
        self.frames = []
        self._closed = False

    def write(self, frame):
        self.frames.append(frame)
        return True


@pytest.fixture
def call(tmp_path, monkeypatch):
    monkeypatch.setenv('HERMES_HOME', str(tmp_path))
    owner = Transport()
    session = dict(session_key='bot', profile_home=str(tmp_path), history=[],
                   history_lock=threading.Lock(), transport=owner, source='desktop')
    monkeypatch.setattr(server, '_sessions', {'runtime': session})
    fields = dict(call_id='call-one', delegation_id='delegation-one', client_turn_id='turn-one')
    def invoke(method='voice.live.call.bind', transport=owner, **extra):
        return server.dispatch({'id': 1, 'method': method,
                                'params': dict(session_id='runtime', **(fields | extra))}, transport=transport)
    assert invoke()['result']['bound'] is True
    return owner, session, fields, invoke


def test_typed_action_is_exact_scoped_direct_and_idempotent(call, tmp_path):
    from tui_gateway.voice_call_control import request_end, voice_call_turn
    owner, session, fields, invoke = call
    foreign = Transport()
    assert 'error' in invoke(transport=foreign)
    assert 'error' in invoke(call_id='another-call')
    with voice_call_turn(session, 'turn-one'):
        assert request_end(**(fields | {'call_id': 'foreign'}))['requested'] is False
        assert request_end(**(fields | {'delegation_id': 'old-delegation'}))['requested'] is False
        assert request_end(**fields) == {'requested': True}
        assert request_end(**fields) == {'requested': True}
    assert len(owner.frames) == 1
    assert owner.frames[0]['params'] == dict(type='voice.live.call.end', session_id='runtime', payload=fields)
    assert not foreign.frames
    assert 'error' in invoke(delegation_id='new-delegation')


def test_stale_turn_disconnect_wrong_profile_and_plain_text_are_inert(call, tmp_path):
    from tui_gateway.voice_call_control import request_end, voice_call_turn
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    owner, session, fields, invoke = call
    # A quoted/echoed instruction has no execution scope and cannot emit an action.
    session['history'].append({'role': 'assistant', 'content': 'request_mobile_contact kind=end_call'})
    assert request_end(**fields)['requested'] is False
    with voice_call_turn(session, 'old-turn'):
        assert request_end(**fields)['requested'] is False
    assert invoke(delegation_id='next-delegation', client_turn_id='next-turn')['result']['bound'] is True
    with voice_call_turn(session, 'turn-one'):
        assert request_end(**fields)['requested'] is False
    with voice_call_turn(session, 'next-turn'):
        token = set_hermes_home_override(str(tmp_path / 'foreign-profile'))
        try:
            assert request_end(**(fields | {'delegation_id': 'next-delegation', 'client_turn_id': 'next-turn'}))['requested'] is False
        finally:
            reset_hermes_home_override(token)
    server._detach_session_transport(session, owner)
    assert 'voice_live_call' not in session
    with voice_call_turn(session, 'next-turn'):
        assert request_end(**fields)['requested'] is False
    assert owner.frames == []


def test_copied_context_expires_with_turn_and_child_cannot_control_parent(call):
    from contextvars import copy_context
    from agent.delegation_context import delegated_child_context
    from tui_gateway.voice_call_control import request_end, voice_call_turn
    owner, session, fields, _invoke = call
    with voice_call_turn(session, 'turn-one'):
        copied = copy_context()
        with delegated_child_context('child'):
            assert request_end(**fields)['requested'] is False
    assert copied.run(request_end, **fields)['requested'] is False
    assert owner.frames == []
