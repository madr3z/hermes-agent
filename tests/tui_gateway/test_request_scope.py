"""Selective clients can answer only the current attached request owner."""

import threading

import pytest

from tui_gateway import server_requests
from tui_gateway.transport import bind_transport


@pytest.fixture
def runtime(tmp_path, monkeypatch):
    from tui_gateway import server
    from tui_gateway.ws import WSTransport

    class Peer(WSTransport):
        def __init__(self):
            self._ws, self._loop, self._peer, self.auth_identity = object(), None, "test", None
            self.frames = []

        def write(self, frame):
            self.frames.append(frame)
            return True

    owner, foreign = Peer(), Peer()
    record = {"session_key": "saved", "transport": owner, "profile_home": str(tmp_path),
              "history_lock": threading.Lock(), "history": [], "agent_ready": None}
    monkeypatch.setitem(server._sessions, "chat", record)
    monkeypatch.setattr(server, "_hermes_home", tmp_path)
    monkeypatch.setattr(server, "_profile_home", lambda profile: tmp_path if profile == "default" else tmp_path / "other")
    server_requests.reset_for_tests()

    def call(peer, method, **params):
        with bind_transport(peer):
            return server.handle_request({"id": 1, "method": method, "params": params})

    yield server, owner, foreign, record, call
    server_requests.reset_for_tests()
    server._sessions.pop("chat", None)


def test_scoped_answers_lock_ack_and_raw_frames_reject_foreign_owners(runtime):
    server, owner, foreign, record, call = runtime
    call(owner, "client.capabilities", server_request_methods=["clarify", "approval"])
    call(foreign, "client.capabilities", server_requests=True)
    req = server_requests.ServerRequest("chat", "clarify", {}, qids=["q"])
    server_requests._open[req.id] = req
    for peer, sid, profile in ((foreign, "chat", "default"), (owner, "other", "default"), (owner, "chat", "other")):
        assert call(peer, "request.answer", id=req.id, result={}, session_id=sid, profile=profile)["result"]["status"] == "expired"
        assert call(peer, "clarify.lock", request_id=req.id, question_id="q", answer="no", session_id=sid, profile=profile)["result"]["status"] == "expired"
    assert not server_requests.resolve_response({"id": req.id, "result": {}}, foreign)
    assert not req.event.is_set() and not req.locked
    record["auth_user_id"] = "basic:owner"
    owner.auth_identity = {"provider": "basic", "user_id": "foreign"}
    assert not server_requests.resolve_response({"id": req.id, "result": {}}, owner)
    owner.auth_identity = {"provider": "basic", "user_id": "owner"}
    assert "error" in call(foreign, "approval.received", session_id="chat", profile="default", request_id="queue")
    assert call(owner, "approval.received", session_id="chat", profile="default", request_id="queue")["result"]["acknowledged"] is False
    assert call(owner, "clarify.lock", request_id=req.id, question_id="q", answer="yes", session_id="chat", profile="default")["result"]["remaining"] == []
    assert req.result == {"answers": {"q": "yes"}, "outcome": "submitted"}
    stale = server_requests.ServerRequest("chat", "approval", {})
    server_requests._open[stale.id] = stale
    server._sessions["chat"] = dict(record)
    assert call(owner, "request.answer", id=stale.id, result={"choice": "once"})["result"]["status"] == "expired"
    server._sessions["chat"] = record
    # Older full clients may omit new session/profile fields; attachment still authorizes them.
    call(owner, "client.capabilities", server_requests=True)
    assert call(owner, "request.answer", id=stale.id, result={"choice": "once"})["result"]["status"] == "ok"


def test_selective_client_never_receives_or_settles_secret_and_full_client_still_can(runtime):
    server, owner, _foreign, _record, call = runtime
    caps = call(owner, "client.capabilities", server_request_methods=["approval", "clarify"])["result"]
    assert caps["scoped_request_answers"] and caps["server_request_methods"] == ["approval", "clarify"]
    result = []
    server_requests.send_async("secret", "chat", {"title": "Credential", "body": "Enter secret", "fields": []}, result.append)
    assert result == [None] and owner.frames == []
    call(owner, "client.capabilities", server_requests=True)
    # A synthetic registered request isolates transport authority from model/provider calls.
    req = server_requests.ServerRequest("chat", "secret", {})
    server_requests._open[req.id] = req
    call(owner, "client.capabilities", server_request_methods=["approval", "clarify"])
    assert not server._write_request_transport(owner, req.frame())
    assert not server_requests.resolve_response({"id": req.id, "result": {}}, owner)
    call(owner, "client.capabilities", server_requests=True)
    assert server._write_request_transport(owner, req.frame())
    assert server_requests.resolve_response({"id": req.id, "result": {"values": {}}}, owner)
    assert req.event.is_set()


def test_selective_fanout_and_compute_mirror_keep_exact_owner(runtime, monkeypatch):
    import asyncio
    from tui_gateway.transport import FanoutTransport

    server, owner, other, record, call = runtime
    loop = asyncio.new_event_loop()
    worker = threading.Thread(target=loop.run_forever, daemon=True)
    worker.start()
    delivered = threading.Event()
    for peer in (owner, other):
        async def write_async(frame, peer=peer):
            peer.write(frame)
            delivered.set()
            return True
        peer._loop, peer.write_async = loop, write_async
    record["transport"] = FanoutTransport(owner, other)
    call(owner, "client.capabilities", server_request_methods=["approval", "clarify"])
    call(other, "client.capabilities", server_requests=True)
    try:
        assert server._write_request_transport(record["transport"], {"id": "synthetic", "method": "secret", "params": {"session_id": "chat"}})
        assert delivered.wait(2)
        assert owner.frames == [] and other.frames[0]["method"] == "secret"
        preview = server_requests.ServerRequest("chat", "preview.read", {})
        server_requests._open[preview.id] = preview
        assert server_requests.resolve_response({"id": preview.id, "error": {"code": server_requests.NOT_SHOWN_CODE}}, other)
        assert preview.event.is_set()  # A phone without this method is not a declining-window voter.
        record["_compute_host_open_request"] = {"id": "mirrored", "method": "clarify", "params": {"session_id": "chat"}}
        monkeypatch.setattr(server, "_session_uses_compute_host", lambda session: True)
        relayed = []
        from types import SimpleNamespace
        monkeypatch.setattr(server, "_get_compute_host_supervisor", lambda: SimpleNamespace(respond=lambda sid, payload: relayed.append((sid, payload))))
        # Method-selective advertisements alone grant no authority to a detached connection.
        record["transport"].detach(owner)
        assert call(owner, "request.answer", id="mirrored", result={}, session_id="chat", profile="default")["result"]["status"] == "expired"
        assert call(other, "request.answer", id="mirrored", result={}, session_id="other", profile="default")["result"]["status"] == "expired"
        assert not relayed and record["_compute_host_open_request"]["id"] == "mirrored"
        assert call(other, "request.answer", id="mirrored", result={}, session_id="chat", profile="default")["result"]["status"] == "ok"
        assert relayed[0][0] == "chat" and "_compute_host_open_request" not in record
    finally:
        loop.call_soon_threadsafe(loop.stop)
        worker.join(2)
        loop.close()
