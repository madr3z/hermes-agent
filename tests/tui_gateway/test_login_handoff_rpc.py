"""Human login actions require an attached chat transport and the owning profile."""
import io
import threading
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager

from hermes_constants import get_hermes_home
from hermes_state import SessionDB
from tools.connectors import login_handoff as login
from tui_gateway import server
from tui_gateway.transport import StdioTransport


def test_chat_login_rpc_rejects_foreign_transport_and_profile(monkeypatch, tmp_path):
    home = get_hermes_home()
    db = SessionDB(home / "state.db")
    db.create_session("owned-chat", source="desktop")
    @contextmanager
    def session_db(_):
        yield db
    owner = StdioTransport(lambda: io.StringIO(), threading.Lock())
    stranger = StdioTransport(lambda: io.StringIO(), threading.Lock())
    session = {"session_key": "owned-chat", "profile_home": str(home), "transport": owner, "source": "desktop"}
    monkeypatch.setitem(server._sessions, "runtime-chat", session)
    monkeypatch.setattr(server, "_session_db", session_db)
    monkeypatch.setattr(server, "_session_uses_compute_host", lambda _: False)
    monkeypatch.setattr(server, "_load_cfg", lambda: {"model": {"provider": "openai-codex"}})
    monkeypatch.setattr(server, "_profile_home", lambda _: tmp_path / "foreign-profile")
    def call(transport, **extra):
        return server.dispatch({"jsonrpc": "2.0", "id": 1, "method": "login.handoff.list",
                                "params": {"session_id": "runtime-chat", **extra}}, transport)
    try:
        assert call(stranger)["error"]["code"] == 4001
        assert call(owner, profile="foreign")["error"]["code"] == 4001
        records = call(owner)["result"]["requests"]
        assert len(records) == 1 and records[0]["provider"] == "openai-codex"
        assert session["_login_handoff_chat"] == "owned-chat"
        request_id = records[0]["id"]
        assert login.list_requests(tmp_path / "foreign-profile", "owned-chat", required=False) == []
        assert login.cancel(home, "owned-chat", request_id)["status"] == "canceled"
    finally:
        db.close()


def test_concurrent_confirmation_consumes_one_durable_handoff_before_prompt_admission(monkeypatch):
    home = get_hermes_home()
    db = SessionDB(home / "state.db")
    db.create_session("owned-chat", source="desktop")
    @contextmanager
    def session_db(_):
        yield db
    owner = StdioTransport(lambda: io.StringIO(), threading.Lock())
    session = {"session_key": "owned-chat", "profile_home": str(home), "transport": owner, "source": "desktop"}
    monkeypatch.setitem(server._sessions, "runtime-chat", session)
    monkeypatch.setattr(server, "_session_db", session_db)
    monkeypatch.setattr(server, "_session_uses_compute_host", lambda _: False)
    monkeypatch.setattr(login, "local_account", lambda _: "account-a")
    record = {"id": "handoff-a", "chat": "owned-chat", "provider": login.PROVIDER,
              "name": "Codex", "scopes": [], "status": "authorized", "detail": "Confirm account",
              "account_ref": "account-a", "user_code": "", "verification_url": "",
              "expires_at": 0.0, "continued": False}
    with login._database(home) as store:
        login._write(store, record)
    entered, release = threading.Event(), threading.Event()
    submissions = []
    def submit(rid, params):
        submissions.append(params)
        entered.set()
        if len(submissions) == 1:
            assert release.wait(5)
        return {"jsonrpc": "2.0", "id": rid, "result": {"status": "queued"}}
    monkeypatch.setitem(server._methods, "prompt.submit", submit)
    def call():
        token = server.bind_transport(owner)
        try:
            return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": "login.handoff.continue",
                "params": {"session_id": "runtime-chat", "request_id": "handoff-a"}})
        finally:
            server.reset_transport(token)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(call)
            assert entered.wait(5)
            second = pool.submit(call)
            try:
                receipt = second.result(timeout=3)["result"]["request"]
                assert len(submissions) == 1
                assert receipt["continued"] and receipt["continuation_status"] == "unconfirmed"
            finally:
                release.set()
            assert first.result(timeout=5)["result"]["request"]["continuation_status"] == "submitted"
        assert call()["result"]["request"]["continued"]
        assert len(submissions) == 1
    finally:
        release.set()
        db.close()
