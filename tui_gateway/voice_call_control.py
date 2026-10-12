"""Typed controls for the call and delegated turn owned by one live client."""
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path

_current_turn = ContextVar('voice_call_turn', default=None)
_KEYS = ('call_id', 'delegation_id', 'client_turn_id')


@contextmanager
def voice_call_turn(session, client_turn_id):
    grant = {'session': session, 'client_turn_id': client_turn_id, 'active': True}
    token = _current_turn.set(grant)
    try:
        yield
    finally:
        grant['active'] = False
        _current_turn.reset(token)


def bind_call(session, transport, fields):
    from tui_gateway import server
    if bool(fields.get('delegation_id')) != bool(fields.get('client_turn_id')):
        raise ValueError('Delegation and turn identity must be supplied together')
    with server._session_transport_lock:
        previous = session.get('voice_live_call')
        if previous and (previous['transport'] is not transport or previous['call_id'] != fields['call_id']):
            raise ValueError('Another call owns this conversation')
        if previous and previous.get('closing'):
            raise ValueError('This call is ending')
        session['voice_live_call'] = {**{key: fields.get(key) for key in _KEYS}, 'transport': transport}


def unbind_call(session, transport, call_id):
    from tui_gateway import server
    with server._session_transport_lock:
        binding = session.get('voice_live_call')
        if binding and binding['transport'] is transport and binding['call_id'] == call_id:
            session.pop('voice_live_call', None)


def request_end(call_id, delegation_id, client_turn_id):
    """Only a real tool call in the exact voice turn can emit the non-replayed action."""
    from agent.delegation_context import is_delegated_child_context
    from hermes_constants import get_hermes_home
    from tui_gateway import server
    unavailable = {'requested': False, 'error': 'This delegated turn does not own an active voice call.'}
    current = _current_turn.get()
    if current is None or not current['active'] or is_delegated_child_context():
        return unavailable
    session, executing_turn_id = current['session'], current['client_turn_id']
    fields = dict(zip(_KEYS, (call_id, delegation_id, client_turn_id)))
    if any(not isinstance(value, str) or not 1 <= len(value) <= 200 for value in fields.values()):
        return unavailable
    if executing_turn_id != client_turn_id or not session.get('profile_home') or Path(session['profile_home']).resolve() != Path(get_hermes_home()).resolve():
        return unavailable
    with server._sessions_lock, server._session_transport_lock:
        sid = next((sid for sid, record in server._sessions.items() if record is session), None)
        binding = session.get('voice_live_call')
        if not current['active'] or not sid or not binding or any(binding.get(key) != value for key, value in fields.items()):
            return unavailable
        transport = binding['transport']
        if not server._transport_is_live_peer(transport) or not server._session_transport_contains(session, transport):
            session.pop('voice_live_call', None)
            return unavailable
        if binding.get('closing'):
            return {'requested': True}
        # Direct delivery avoids fanout to other viewers and replay into a later call.
        if transport.write(server._event_frame("voice.live.call.end", sid, fields)) is False:
            return unavailable
        binding['closing'] = True
        return {'requested': True}
