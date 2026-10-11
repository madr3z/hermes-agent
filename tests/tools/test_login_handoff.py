"""Login grants stay with the requesting profile; canceled/restarted attempts cannot resume."""
import base64
import json
import threading
import time
from pathlib import Path

import pytest
from hermes_constants import get_hermes_home
from tools.connectors import login_handoff as login


def token(account="account-a", subject="user-a"):
    claims = {"sub": subject, "https://api.openai.com/auth": {"chatgpt_account_id": account}}
    return "e30." + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=") + ".signature"


def wait_for(home, chat, status):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        records = login.list_requests(home, chat, required=False)
        if records and records[0]["status"] == status:
            return records[0]
        time.sleep(0.01)
    raise AssertionError(f"No {status} status: {records}")


def test_codex_grant_stays_local_and_cancel_wins(monkeypatch, tmp_path):
    from hermes_cli.web_routers import oauth
    from hermes_cli import auth
    home = Path(get_hermes_home())
    ready, release = threading.Event(), threading.Event()
    saves = []
    monkeypatch.setattr(oauth, "_codex_request_user_code", lambda _: {"user_code": "UI-ONLY-CANARY", "device_auth_id": "PRIVATE-CANARY", "interval": 3})
    def poll(*args):
        ready.set()
        assert release.wait(5)
        return {"authorization_code": "PRIVATE-CODE", "code_verifier": "PRIVATE-PKCE"}
    monkeypatch.setattr(oauth, "_codex_poll_authorization", poll)
    monkeypatch.setattr(oauth, "_codex_exchange_tokens", lambda *_: {"access_token": token(), "refresh_token": "PRIVATE-REFRESH"})
    monkeypatch.setattr(auth, "_save_codex_tokens", lambda value, **_: saves.append(value))
    record = login.list_requests(home, "chat-a", required=True)[0]
    login.start(home, "chat-a", record["id"])
    assert ready.wait(5)
    assert login.list_requests(home, "chat-b", required=False) == []
    with pytest.raises(ValueError): login.cancel(home, "chat-b", record["id"])
    with pytest.raises(ValueError): login.cancel(tmp_path / "other-profile", "chat-a", record["id"])
    assert login.cancel(home, "chat-a", record["id"])["status"] == "canceled"
    release.set()
    deadline = time.monotonic() + 5
    while record["id"] in login._ACTIVE and time.monotonic() < deadline: time.sleep(0.01)
    assert not saves
    assert "PRIVATE-CANARY" not in (home / "login-handoffs.db").read_bytes().decode(errors="ignore")
    assert (home / "login-handoffs.db").stat().st_mode & 0o777 == 0o600


def test_authorized_request_survives_reopen_and_rejects_account_switch(monkeypatch):
    from hermes_cli.web_routers import oauth
    from hermes_cli import auth
    home = Path(get_hermes_home())
    monkeypatch.setattr(oauth, "_codex_request_user_code", lambda _: {"user_code": "USER-CODE", "device_auth_id": "DEVICE-SECRET", "interval": 3})
    monkeypatch.setattr(oauth, "_codex_poll_authorization", lambda *_: {"authorization_code": "SECRET"})
    monkeypatch.setattr(oauth, "_codex_exchange_tokens", lambda *_: {"access_token": token(), "refresh_token": "SECRET-REFRESH"})
    # Use the existing profile-aware saver, with a fixed fixture grant and no network.
    record = login.list_requests(home, "chat-a", required=True)[0]
    login.start(home, "chat-a", record["id"])
    approved = wait_for(home, "chat-a", "authorized")
    assert approved["account_ref"] == login.local_account(home)
    assert approved["user_code"] == "" and "SECRET" not in json.dumps(approved)
    monkeypatch.setattr(login, "_INSTANCE", "reopened-gateway")
    assert login.continuation(home, "chat-a", record["id"])["status"] == "authorized"
    login.mark_continued(home, "chat-a", record["id"])
    assert login.list_requests(home, "chat-a", required=False)[0]["continued"]
    auth._save_codex_tokens({"access_token": token("account-b"), "refresh_token": "OTHER-SECRET"}, set_active=False)
    with pytest.raises(ValueError): login.continuation(home, "chat-a", record["id"])
    assert login.list_requests(home, "chat-a", required=False)[0]["status"] == "failed"


def test_restart_expires_unfinished_attempt_without_secret_replay(monkeypatch):
    home = Path(get_hermes_home())
    record = login.list_requests(home, "chat-a", required=True)[0]
    with login._database(home) as db:
        stored = login._read(db, record["id"], "chat-a")
        stored.update(instance="old-instance", pid=999999999, process_started=0, expires_at=time.time() + 900, user_code="OLD-CODE")
        login._write(db, stored)
    recovered = login.list_requests(home, "chat-a", required=False)[0]
    assert recovered["status"] == "expired" and recovered["user_code"] == ""
    with pytest.raises(ValueError): login.continuation(home, "chat-a", record["id"])


def test_mcp_chat_callback_uses_existing_state_and_profile_checks(monkeypatch):
    import asyncio
    from hermes_cli import mcp_config
    from tools.connectors import mcp_oauth
    from tools.mcp_dashboard_oauth import DashboardOAuthFlow
    from tui_gateway import mcp_oauth_sessions
    home = Path(get_hermes_home())
    cfg = {"linear": {"url": "https://mcp.linear.app/mcp", "auth": "oauth"}}
    monkeypatch.setattr(mcp_config, "_get_mcp_servers", lambda: cfg)
    flow = DashboardOAuthFlow(flow_id="fixture-flow", server_name="linear", profile=None,
                              hermes_home=str(home), redirect_uri="com.hermes.iphone:/oauth/callback", reconnect_live=False)
    asyncio.run(flow.publish_authorization_url("https://linear.app/oauth/authorize?state=owned-state&scope=read&redirect_uri=com.hermes.iphone%3A%2Foauth%2Fcallback"))
    mcp_oauth_sessions.register_flow(flow)
    monkeypatch.setattr(mcp_oauth, "start", lambda *a, **k: mcp_oauth.OAuthAttempt(flow.authorization_url, flow))
    record = login.create_mcp(home, "chat-a", "linear")
    login.start(home, "chat-a", record["id"], client_redirect_uri="com.hermes.iphone:/oauth/callback")
    deadline = time.monotonic() + 5
    while not login.list_requests(home, "chat-a", required=False)[0]["auth_url"] and time.monotonic() < deadline: time.sleep(0.01)
    current = login.list_requests(home, "chat-a", required=False)[0]
    assert current["scopes"] == ["read"]
    with pytest.raises(ValueError):
        login.callback(home, "chat-b", record["id"], {"code": "secret", "state": "owned-state"})
    with pytest.raises(ValueError):
        login.callback(home, "chat-a", record["id"], {"code": "secret", "state": "wrong-state"})
    login.callback(home, "chat-a", record["id"], {"code": "secret", "state": "owned-state"})
    with pytest.raises(ValueError):
        login.callback(home, "chat-a", record["id"], {"code": "secret", "state": "owned-state"})
    flow.mark_approved()
    approved = wait_for(home, "chat-a", "authorized")
    assert not approved["auth_url"]
    assert "secret" not in (home / "login-handoffs.db").read_bytes().decode(errors="ignore")
