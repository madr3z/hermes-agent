"""Google adapter insertion into the existing chat-owned login lifecycle."""

import hashlib
import json


def worker(home, chat, request_id, attempt, client_redirect_uri):
    from tools.connectors import login_handoff as login, google_gmail_login as google
    from tools.connectors.mcp_oauth import NATIVE_CLIENT_REDIRECT_URI
    from hermes_cli.mcp_config import _get_mcp_servers

    try:
        if client_redirect_uri != NATIVE_CLIENT_REDIRECT_URI:
            raise ValueError("Use the native phone callback for Google sign-in")
        with login._LOCK, login._database(home) as db:
            record = login._read(db, request_id, chat)
            if login._ACTIVE.get(request_id) is not attempt or attempt["cancelled"]:
                return
            cfg = _get_mcp_servers().get(record["name"]) or {}
            if hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest() != record["config_ref"]:
                raise ValueError("The selected account configuration changed")
            from tools.mcp_tool_discovery import register_mcp_servers
            # This starts the selected transport. Existing conversations retain
            # their cached tool definitions; new tools apply in a new session.
            register_mcp_servers({record["name"]: cfg})
            prepared = google.begin(attempt, home, record["name"], cfg, expires_at=record["expires_at"])
            attempt["auth_url"] = prepared["auth_url"]
            record.update(scopes=prepared["scopes"], detail="Sign in to the requested Google account. The bot verifies Google's returned email before accepting access.")
            login._write(db, record)
    except Exception:  # health: allow BLE001 -- Keep provider URLs and credentials out of status and logs.
        login._update(home, chat, request_id, attempt, status="failed", detail="Google sign-in could not start. Check the installed connector, client registration and private HTTPS callback.")


def callback(home, chat, record, attempt, params):
    """Caller holds the lifecycle lock and its database transaction."""
    from tools.connectors import google_gmail_login as google
    from hermes_cli.mcp_config import _get_mcp_servers

    cfg = _get_mcp_servers().get(record["name"]) or {}
    try:
        if hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest() != record["config_ref"]:
            raise ValueError("The selected account configuration changed")
        accepted = google.complete(attempt, home, record["name"], cfg, params)
        record.update(accepted, status="authorized", detail="Google verified this account. Confirm to continue the task.")
    except ValueError:
        google.cancel(attempt)
        record.update(status="failed", detail="Google sign-in was rejected, expired or used a different account. Retry sign-in.")
    return record


def observe(home, chat):
    from tools.connectors import login_handoff as login, google_gmail_login as google

    with login._LOCK, login._database(home) as db:
        records = [login._recover(json.loads(row[0])) for row in db.execute("SELECT body FROM requests WHERE chat=?", (chat,))]
        for record in records:
            if record["provider"] != "google-gmail" or record["status"] != "expired":
                continue
            if attempt := login._ACTIVE.pop(record["id"], None):
                google.cancel(attempt)
            login._write(db, record)


def verified_identity(home, name, config):
    """Show an accepted identity only while its exact account grant is unchanged."""
    import sqlite3
    from tools.connectors.google_gmail_login import grant_ref

    path = home / "login-handoffs.db"
    if not path.is_file():
        return None
    try:
        current = grant_ref(home, name, config)
    except (ValueError, KeyError):
        return None
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        for (body,) in db.execute("SELECT body FROM requests"):
            record = json.loads(body)
            if (record["provider"] == "google-gmail" and record["name"] == name
                    and record["status"] == "authorized" and current
                    and current == record.get("grant_ref")
                    and hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest() == record["config_ref"]):
                return record.get("verified_identity")
    return None
