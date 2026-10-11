"""Human login actions require an attached chat transport and the owning profile."""
import io
import threading
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
