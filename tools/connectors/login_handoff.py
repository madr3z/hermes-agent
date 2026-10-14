"""Durable, status-only Codex login requests. Device secrets never enter chat history."""
from __future__ import annotations

import contextvars
import hashlib
import json
import os
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

PROVIDER = "openai-codex"
VERIFICATION_URL = "https://auth.openai.com/codex/device"
_INSTANCE = uuid.uuid4().hex
_LOCK = threading.RLock()
_ACTIVE: dict[str, dict] = {}


@contextmanager
def _database(home: Path):
    home.mkdir(parents=True, exist_ok=True)
    path = home / "login-handoffs.db"
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    os.chmod(path, 0o600)
    with sqlite3.connect(path, timeout=15) as db:
        db.row_factory = sqlite3.Row
        db.execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, chat TEXT NOT NULL, body TEXT NOT NULL)")
        db.execute("BEGIN IMMEDIATE")
        yield db


def local_account(home: Path) -> str:
    """Read only this profile's grant. Never adopt a root or local Codex CLI grant."""
    from agent.credential_pool import _codex_principal_identity
    path = home / "auth.json"
    if not path.exists():
        return ""
    state = json.loads(path.read_text(encoding="utf-8-sig"))
    tokens = state.get("providers", {}).get(PROVIDER, {}).get("tokens", {})
    if not tokens.get("refresh_token"):
        entries = state.get("credential_pool", {}).get(PROVIDER, [])
        tokens = next((entry for entry in entries if isinstance(entry, dict) and entry.get("refresh_token")
                       and entry.get("status") != "dead"), {})
    principal = _codex_principal_identity(tokens.get("access_token"))
    return hashlib.sha256(json.dumps(principal).encode()).hexdigest()[:16] if principal else ""


def _write(db, record):
    db.execute("INSERT OR REPLACE INTO requests VALUES (?, ?, ?)",
               (record["id"], record["chat"], json.dumps(record)))


def _read(db, request_id: str, chat: str):
    row = db.execute("SELECT body FROM requests WHERE id=? AND chat=?", (request_id, chat)).fetchone()
    if row is None:
        raise ValueError("Login request not found in this chat")
    return json.loads(row[0])


def _recover(record):
    if record["status"] == "awaiting_human" and record.get("instance"):
        alive = True
        if record["instance"] != _INSTANCE:
            import psutil
            try:
                alive = psutil.Process(record.get("pid", -1)).create_time() == record.get("process_started")
            except (psutil.NoSuchProcess, psutil.AccessDenied, ValueError):
                alive = False
        if record["expires_at"] <= time.time() or not alive:
            record.update(status="expired", detail="Sign-in expired or the gateway restarted. Start a new attempt.", user_code="")
    return record


def public(record):
    from hermes_constants import get_hermes_home, profile_name_for_home
    record = dict(record, auth_url="", owner_profile=profile_name_for_home(get_hermes_home()) or "owning bot")
    active = _ACTIVE.get(record["id"])
    if active and record["status"] == "awaiting_human":
        record["auth_url"] = active["oauth"].auth_url if active.get("oauth") else active.get("auth_url", "")
    return {**{key: record[key] for key in (
        "id", "provider", "name", "owner_profile", "scopes", "auth_url", "status", "detail", "account_ref", "user_code", "verification_url", "expires_at", "continued")},
        "verified_identity": record.get("verified_identity"), "attempt_id": record.get("attempt_id"),
        "continuation_status": record.get("continuation_status", "")}


def list_requests(home: Path, chat: str, *, required: bool):
    _observe_mcp(home, chat)
    from tools.connectors.login_handoff_google import observe
    observe(home, chat)
    with _LOCK, _database(home) as db:
        records = [_recover(json.loads(row[0])) for row in db.execute(
            "SELECT body FROM requests WHERE chat=?", (chat,))]
        if not records and required and not local_account(home):
            records = [{"id": uuid.uuid4().hex, "chat": chat, "provider": PROVIDER,
                        "name": "ChatGPT / Codex", "scopes": ["Codex subscription access (provider-defined)"], "status": "awaiting_human", "detail": "Sign in to use this bot's Codex subscription.",
                        "account_ref": "", "user_code": "", "verification_url": VERIFICATION_URL,
                        "expires_at": 0.0, "continued": False}]
        for record in records:
            _write(db, record)
        return [public(record) for record in records]


def start(home: Path, chat: str, request_id: str, *, client_redirect_uri=None):
    from tools.connectors.login_handoff_providers import provider_for, providers, release_attempt
    for provider in providers():
        provider.observe(home, chat)
    with _LOCK, _database(home) as db:
        record = _recover(_read(db, request_id, chat))
        provider = provider_for(record["provider"])
        if record["status"] == "authorized":
            return public(record)
        if (record.get("instance") and record["instance"] != _INSTANCE
                and record["status"] == "awaiting_human"):
            raise ValueError("This request is active on another gateway process")
        if provider.requires_redirect() and not client_redirect_uri:
            raise ValueError("Use a native client callback for remote MCP sign-in")
        if record.get("instance") == _INSTANCE and request_id in _ACTIVE:
            previous = _ACTIVE[request_id]
            oauth = previous.get("oauth")
            if (record["status"] == "awaiting_human" and not previous["cancelled"]
                    and (oauth is None or oauth.flow.redirect_uri == client_redirect_uri)):
                return public(record)
            release_attempt(previous)
        import psutil
        record.update(status="awaiting_human", detail="Preparing provider sign-in…", user_code="",
                      instance=_INSTANCE, pid=os.getpid(), process_started=psutil.Process().create_time(),
                      expires_at=time.time() + 900, continued=False, verified_identity=None, grant_ref="",
                      attempt_id=uuid.uuid4().hex)
        _write(db, record)
        attempt = {"cancelled": False, "attempt_id": record["attempt_id"]}
        _ACTIVE[request_id] = attempt
    threading.Thread(target=contextvars.copy_context().run, args=(provider.worker(), home, chat, request_id, attempt, client_redirect_uri),
                     daemon=True, name="codex-login-handoff").start()
    return public(record)


def cancel(home: Path, chat: str, request_id: str, *, attempt_id=None):
    with _LOCK, _database(home) as db:
        record = _recover(_read(db, request_id, chat))
        if attempt_id is not None and attempt_id != record.get("attempt_id"):
            return public(record)
        if record["status"] == "authorized":
            return public(record)  # Cancellation cannot revoke a committed grant.
        if (record.get("instance") and record["instance"] != _INSTANCE
                and record["status"] == "awaiting_human"):
            raise ValueError("Cancel on the gateway process that owns this sign-in")
        if attempt := _ACTIVE.get(request_id):
            from tools.connectors.login_handoff_providers import provider_for
            if saved := provider_for(record["provider"]).absorb_cancel(home, record, attempt):
                record.update(saved)
                _write(db, record)
                return public(record)
            attempt["cancelled"] = True
        record.update(status="canceled", detail="Sign-in canceled. The task has not resumed.", user_code="")
        _write(db, record)
        return public(record)


def cancel_server_requests(home: Path, name: str):
    """Retire this profile's sign-in requests before deleting the account grant."""
    with _LOCK, _database(home) as db:
        records = [json.loads(row[0]) for row in db.execute("SELECT body FROM requests")]
        from tools.connectors.login_handoff_providers import provider_for, release_attempt
        for record in records:
            if not provider_for(record["provider"]).owns_removed_account(record, name):
                continue
            attempt = _ACTIVE.pop(record["id"], None)
            if attempt is not None:
                release_attempt(attempt)
            record.update(status="canceled", detail="This account was removed. The task has not resumed.",
                          user_code="", grant_ref="")
            _write(db, record)


def continuation(home: Path, chat: str, request_id: str):
    with _LOCK, _database(home) as db:
        record = _read(db, request_id, chat)
        if record["status"] != "authorized":
            raise ValueError("Sign in before continuing")
        from tools.connectors.login_handoff_providers import provider_for
        changed = provider_for(record["provider"]).account_changed(home, record)
        if changed:
            record.update(status="failed", detail="The authorized account or server slot changed. Sign in again before continuing.")
            _write(db, record)
    if changed:
        raise ValueError("Authorized account changed")
    return record


def claim_continuation(home: Path, chat: str, request_id: str):
    """Consume one handoff before admission. An uncertain admission must never replay."""
    with _LOCK, _database(home) as db:
        record = _read(db, request_id, chat)
        if record["continued"]:
            return False, public(record)
        record.update(continued=True, continuation_status="unconfirmed",
                      detail="Task continuation is unconfirmed. Check this chat before sending another message.")
        _write(db, record)
        return True, public(record)


def mark_continued(home: Path, chat: str, request_id: str):
    with _LOCK, _database(home) as db:
        record = _read(db, request_id, chat)
        record.update(continued=True, continuation_status="submitted", detail="Task continuation submitted.")
        _write(db, record)
        return public(record)


def _update(home, chat, request_id, attempt, **fields):
    with _LOCK, _database(home) as db:
        record = _read(db, request_id, chat)
        if attempt["cancelled"] or _ACTIVE.get(request_id) is not attempt:
            return False
        record.update(fields)
        _write(db, record)
        return True


def _worker(home: Path, chat: str, request_id: str, attempt: dict, client_redirect_uri=None):
    from hermes_cli.web_routers import oauth
    from hermes_cli.auth import _save_codex_tokens
    from agent.credential_pool import _codex_principal_identity
    import httpx
    try:
        device = oauth._codex_request_user_code(httpx)
        attempt.update(device, expires_in=900)
        if not _update(home, chat, request_id, attempt, user_code=device["user_code"],
                       detail="Open OpenAI sign-in. Enter this code and approve the intended account."):
            return
        result = oauth._codex_poll_authorization(httpx, attempt, request_id)
        if attempt["cancelled"] or result is oauth._CANCELLED:
            return
        if result is None:
            _update(home, chat, request_id, attempt, status="expired", user_code="", detail="The device code expired. Try again.")
            return
        tokens = oauth._codex_exchange_tokens(httpx, result)
        principal = _codex_principal_identity(tokens.get("access_token"))
        if not principal or not tokens.get("refresh_token"):
            raise ValueError("Provider returned no account-bound grant")
        account_ref = hashlib.sha256(json.dumps(principal).encode()).hexdigest()[:16]
        # Order cancellation and the sole credential write. A stale attempt can never commit.
        with _LOCK, _database(home) as db:
            record = _read(db, request_id, chat)
            if (attempt["cancelled"] or _ACTIVE.get(request_id) is not attempt
                    or record["status"] != "awaiting_human" or time.time() >= record["expires_at"]):
                return
            _save_codex_tokens(tokens, set_active=False)
            record.update(status="authorized", user_code="", account_ref=account_ref,
                          detail="Authorization saved on this bot. Confirm to continue its task.")
            _write(db, record)
    except Exception:  # health: allow BLE001 -- Provider exceptions can contain credentials; expose only fixed failure status.
        # Provider payloads can contain secrets. Publish only a fixed status message.
        _update(home, chat, request_id, attempt, status="failed", user_code="",
                detail="OpenAI sign-in failed. Check device-code permission in ChatGPT settings, then retry.")
    finally:
        with _LOCK:
            if _ACTIVE.get(request_id) is attempt:
                _ACTIVE.pop(request_id, None)


def create_mcp(home: Path, chat: str, name: str):
    from hermes_cli.mcp_config import _get_mcp_servers
    from urllib.parse import urlparse
    from tools.connectors.login_handoff_providers import provider_for_server
    cfg = _get_mcp_servers().get(name) or {}
    url = urlparse(cfg.get("url", ""))
    provider = provider_for_server(cfg, url)
    config_ref = hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()
    with _LOCK, _database(home) as db:
        rows = db.execute("SELECT body FROM requests WHERE chat=?", (chat,))
        for row in rows:
            existing = _recover(json.loads(row[0]))
            if existing["provider"] == provider.name and existing["name"] == name and not existing["continued"]:
                if existing["config_ref"] == config_ref:
                    return public(existing)
                _retire_attempt(existing["id"])
                existing.update(status="canceled", user_code="", grant_ref="",
                                verified_identity=None, detail="The account setup changed. Use its new sign-in request.")
                _write(db, existing)
        record = {"id": uuid.uuid4().hex, "chat": chat, "provider": provider.name, "name": name,
                  "scopes": [], "status": "awaiting_human", "detail": provider.detail(cfg, url),
                  "account_ref": name, "user_code": "", "verification_url": "", "expires_at": 0.0,
                  "continued": False, "config_ref": config_ref}
        _write(db, record)
        return public(record)


def _mcp_worker(home, chat, request_id, attempt, client_redirect_uri):
    from tools.connectors import mcp_oauth
    from hermes_cli.mcp_config import _get_mcp_servers
    from urllib.parse import parse_qs, urlparse
    try:
        with _LOCK, _database(home) as db:
            record = _read(db, request_id, chat)
        cfg = _get_mcp_servers().get(record["name"]) or {}
        if hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest() != record["config_ref"]:
            raise ValueError("Server configuration changed")
        oauth = mcp_oauth.start(record["name"], client_redirect_uri=client_redirect_uri,
                                expires_at=record["expires_at"], expected_config_ref=record["config_ref"])
        with _LOCK:
            attempt["oauth"] = oauth
            if attempt["cancelled"]:
                mcp_oauth.cancel_attempt(oauth.flow)
                return
        scopes = parse_qs(urlparse(oauth.auth_url).query).get("scope", [""])[0].split()
        _update(home, chat, request_id, attempt, scopes=scopes,
                detail="Review the provider account and consent screen. This authorizes API access only.")
    except Exception:  # health: allow BLE001 -- Provider exceptions can contain credentials; expose only fixed failure status.
        _update(home, chat, request_id, attempt, status="failed", detail="MCP sign-in could not start. Check this provider's client registration and callback support.")
        with _LOCK:
            if _ACTIVE.get(request_id) is attempt:
                _ACTIVE.pop(request_id, None)


def _retire_attempt(request_id):
    from tools.connectors.login_handoff_providers import release_attempt
    attempt = _ACTIVE.pop(request_id, None)
    if not attempt:
        return
    release_attempt(attempt)


def _observe_mcp(home, chat):
    from hermes_cli.mcp_config import _get_mcp_servers
    servers = _get_mcp_servers()
    with _LOCK, _database(home) as db:
        rows = db.execute("SELECT body FROM requests WHERE chat=?", (chat,)).fetchall()
        for row in rows:
            record = json.loads(row[0])
            attempt = _ACTIVE.get(record["id"])
            if record["provider"] != "mcp" or not attempt or not attempt.get("oauth"):
                continue
            oauth = attempt["oauth"]
            snapshot = oauth.poll()
            current = servers.get(record["name"]) or {}
            if hashlib.sha256(json.dumps(current, sort_keys=True).encode()).hexdigest() != record["config_ref"]:
                record.update(status="failed", detail="The account setup changed. Select the account again before signing in.")
            if snapshot["status"] != "approved":
                record = _recover(record)
            if record["status"] in {"expired", "canceled", "failed"}:
                _retire_attempt(record["id"])
                _write(db, record)
                continue
            if snapshot["status"] in ("approved", "error"):
                record.update(status="authorized" if snapshot["status"] == "approved" else "failed",
                              grant_ref=_mcp_grant_ref(home, record["name"]) if snapshot["status"] == "approved" else "",
                              detail="Authorization saved in this named server account slot. Confirm to continue." if snapshot["status"] == "approved" else "Provider sign-in failed. Retry or use the supported Mac callback.")
                _write(db, record)
                _ACTIVE.pop(record["id"], None)


def callback(home, chat, request_id, params):
    # Expiry must apply even if the app was suspended and no status poll ran.
    list_requests(home, chat, required=False)
    with _LOCK, _database(home) as db:
        record = _read(db, request_id, chat)
        attempt = _ACTIVE.get(request_id)
        from tools.connectors.login_handoff_providers import provider_for
        updated, commit = provider_for(record["provider"]).complete_callback(
            home, chat, record, attempt, params)
        if commit:
            _write(db, updated)
            _ACTIVE.pop(request_id, None)
            return public(updated)
        record = updated
    return public(record)


def _mcp_grant_ref(home: Path, name: str):
    from hermes_cli.mcp_config import _get_mcp_servers
    from tools.connectors.login_handoff_providers import grant_for
    config = _get_mcp_servers().get(name) or {}
    return grant_for(home, name, config)


def _mcp_token_grant(home: Path, name: str):
    from tools.mcp_oauth import HermesTokenStorage
    storage = HermesTokenStorage(name, hermes_home=home)
    snapshot = storage.snapshot()
    # Opaque provider grants have no universal user-identity API. Pin the accepted credential
    # file until confirmation; any replacement (including refresh) requires another review.
    value = snapshot.get(storage._tokens_path().name, b"")
    return hashlib.sha256(value).hexdigest() if value else ""
