"""Abandoned browser attempts stay terminal and cannot accept a late callback."""
import asyncio
import hashlib
import json
import time

import pytest

from hermes_constants import get_hermes_home
from tools.connectors import login_handoff as login, mcp_oauth
from tools.mcp_dashboard_oauth import DashboardOAuthFlow
from tui_gateway import mcp_oauth_sessions


@pytest.fixture
def pending(monkeypatch):
    from hermes_cli import mcp_config
    home = get_hermes_home()
    config = {"account-a": {"url": "https://mcp.example.test", "auth": "oauth"}}
    monkeypatch.setattr(mcp_config, "_get_mcp_servers", lambda: config)
    record = login.create_mcp(home, "chat-a", "account-a")
    flow = DashboardOAuthFlow("fixture-lifecycle", "account-a", None, str(home),
                              "com.hermes.iphone:/oauth/callback")
    asyncio.run(flow.publish_authorization_url("https://example.test/authorize?state=owned-state"))
    mcp_oauth_sessions.register_flow(flow)
    with login._LOCK, login._database(home) as db:
        stored = login._read(db, record["id"], "chat-a")
        stored.update(instance=login._INSTANCE, expires_at=time.time() + 900)
        login._write(db, stored)
        login._ACTIVE[record["id"]] = {"cancelled": False, "oauth": mcp_oauth.OAuthAttempt(flow.authorization_url, flow)}
    yield home, record, flow, config
    login._ACTIVE.pop(record["id"], None)


def test_cancel_stays_canceled_after_status_refresh(pending):
    home, record, flow, _ = pending
    assert login.cancel(home, "chat-a", record["id"])["status"] == "canceled"
    refreshed = login.list_requests(home, "chat-a", required=False)[0]
    assert refreshed["status"] == "canceled"
    assert not refreshed["auth_url"]
    assert record["id"] not in login._ACTIVE
    assert flow.cancelled


def test_expired_callback_is_rejected_without_a_prior_status_poll(pending):
    home, record, flow, _ = pending
    with login._database(home) as db:
        stored = login._read(db, record["id"], "chat-a")
        stored["expires_at"] = time.time() - 1
        login._write(db, stored)
    with pytest.raises(ValueError):
        login.callback(home, "chat-a", record["id"], {"code": "PRIVATE-CODE", "state": "owned-state"})
    assert login.list_requests(home, "chat-a", required=False)[0]["status"] == "expired"
    assert flow.cancelled
    assert record["id"] not in login._ACTIVE


def test_changed_account_slot_creates_a_fresh_review_and_retires_old_attempt(pending):
    home, record, flow, config = pending
    config["account-a"]["url"] = "https://other.example.test/mcp"
    fresh = login.create_mcp(home, "chat-a", "account-a")
    assert fresh["id"] != record["id"]
    assert fresh["status"] == "awaiting_human"
    assert flow.cancelled
    old = next(row for row in login.list_requests(home, "chat-a", required=False) if row["id"] == record["id"])
    assert old["status"] == "canceled"


def test_expiry_during_token_exchange_cannot_commit(pending, monkeypatch):
    from hermes_cli import mcp_config
    _, _, flow, _ = pending
    saved = []
    monkeypatch.setattr(mcp_config, "_save_mcp_server", lambda *args: saved.append(args) or True)
    flow.expires_at = time.time() - 1
    with pytest.raises(mcp_oauth.AttemptCanceled):
        mcp_oauth._commit("account-a", {}, None, flow)
    assert not saved


def test_changed_slot_during_token_exchange_cannot_overwrite_configuration(pending, monkeypatch):
    from hermes_cli import mcp_config
    _, _, flow, config = pending
    original = dict(config["account-a"])
    flow.expected_config_ref = hashlib.sha256(json.dumps(original, sort_keys=True).encode()).hexdigest()
    config["account-a"]["url"] = "https://other.example.test/mcp"
    saved = []
    monkeypatch.setattr(mcp_config, "_save_mcp_server", lambda *args: saved.append(args) or True)
    with pytest.raises(mcp_oauth.AttemptCanceled):
        mcp_oauth._commit("account-a", original, None, flow)
    assert not saved


def test_completed_authorization_remains_authorized_when_app_returns_after_deadline(pending):
    home, record, flow, _ = pending
    flow.mark_approved()
    with login._database(home) as db:
        stored = login._read(db, record["id"], "chat-a")
        stored["expires_at"] = time.time() - 1
        login._write(db, stored)
    assert login.list_requests(home, "chat-a", required=False)[0]["status"] == "authorized"


def test_old_browser_cleanup_cannot_cancel_a_new_attempt(pending):
    home, record, flow, _ = pending
    with login._database(home) as db:
        stored = login._read(db, record["id"], "chat-a")
        stored["attempt_id"] = "new-attempt"
        login._write(db, stored)
    assert login.cancel(home, "chat-a", record["id"], attempt_id="old-attempt")["status"] == "awaiting_human"
    assert not flow.cancelled
