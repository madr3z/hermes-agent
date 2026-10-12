"""Ownership and selective transport delivery for human requests."""
from __future__ import annotations

from pathlib import Path
from tui_gateway.method_ctx import bind_module


def _request_session_authorized(sid, owner, transport, session_id=None, profile=None, method=None):
    if session_id is not None and session_id != sid:
        return False
    if transport is None or transport is _stdio_transport:
        return True  # In-process bridges and the process-owned stdio channel.
    session = _sessions.get(sid)
    if session is None or session is not owner or not _session_transport_contains(session, transport):
        return False
    if profile is not None:
        try:
            requested = _profile_home(profile) or _hermes_home
        except ProfileUnavailableError:
            return False
        if Path(requested).resolve() != Path(session.get("profile_home") or _hermes_home).resolve():
            return False
    creator, caller = _session_auth_user_id(session), _transport_auth_user_id(transport)
    if creator is not None and caller is not None and creator != caller:
        return False
    from tui_gateway.server_requests import answers_requests
    return answers_requests(transport, method)


def _authorize_server_request(req, transport, session_id, profile):
    return _request_session_authorized(req.sid, req.owner, transport, session_id, profile, req.method)


def _write_request_transport(transport, obj):
    from tui_gateway.server_requests import answers_requests
    from tui_gateway.ws import WSTransport
    method = obj.get("method")
    if isinstance(transport, FanoutTransport):
        peers = {peer for peer in transport.transports()
                 if not isinstance(peer, WSTransport) or answers_requests(peer, method)}
        return transport.write(obj, recipients=peers)
    if isinstance(transport, WSTransport) and not answers_requests(transport, method):
        return False
    return transport.write(obj)


def register(server):
    bind_module(globals(), server)
    from tui_gateway import server_requests
    server_requests.bind_authority(lambda sid: server._sessions.get(sid),
                                   server._authorize_server_request,
                                   lambda sid, method: server._session_client_answers_requests(sid, method))
