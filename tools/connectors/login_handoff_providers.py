"""Chat login providers. The request store dispatches here instead of naming each one."""
from __future__ import annotations


class HandoffProvider:
    """Start, cancel, callback, and grant checks for one sign-in kind."""

    name = ""

    def requires_redirect(self) -> bool:
        return False

    def worker(self):
        from tools.connectors.login_handoff import _worker
        return _worker

    def release(self, attempt) -> None:
        return None

    def absorb_cancel(self, home, record, attempt):
        """Return status fields when cancel finds a grant already saved."""

    def account_changed(self, home, record) -> bool:
        return False

    def owns_removed_account(self, record, account_name: str) -> bool:
        return False

    def observe(self, home, chat) -> None:
        return None

    def accepts_server(self, config: dict, url) -> bool:
        return False

    def detail(self, config: dict, url) -> str:
        return "Authorize the intended account"

    def complete_callback(self, home, chat, record, attempt, params):
        raise ValueError("No active authorization for this chat")


class CodexHandoff(HandoffProvider):
    name = "openai-codex"

    def account_changed(self, home, record) -> bool:
        from tools.connectors.login_handoff import PROVIDER, local_account
        return record["provider"] == PROVIDER and local_account(home) != record["account_ref"]


class McpHandoff(HandoffProvider):
    name = "mcp"

    def requires_redirect(self) -> bool:
        return True

    def worker(self):
        from tools.connectors.login_handoff import _mcp_worker
        return _mcp_worker

    def release(self, attempt) -> None:
        oauth = attempt.get("oauth")
        if oauth is None:
            return
        from tools.connectors.mcp_oauth import cancel_attempt
        cancel_attempt(oauth.flow)

    def absorb_cancel(self, home, record, attempt):
        oauth = attempt.get("oauth")
        if oauth is None:
            return None
        from tools.connectors.login_handoff import _mcp_grant_ref
        from tools.connectors.mcp_oauth import cancel_attempt
        if not cancel_attempt(oauth.flow):
            return None
        return {
            "status": "authorized",
            "user_code": "",
            "grant_ref": _mcp_grant_ref(home, record["name"]),
            "detail": "Authorization was already saved on this bot.",
        }

    def account_changed(self, home, record) -> bool:
        import hashlib
        import json
        from hermes_cli.mcp_config import _get_mcp_servers, _oauth_tokens_present
        from tools.connectors.login_handoff import _mcp_grant_ref
        cfg = _get_mcp_servers().get(record["name"]) or {}
        digest = hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()
        return (digest != record["config_ref"]
                or not _oauth_tokens_present(record["name"])
                or _mcp_grant_ref(home, record["name"]) != record.get("grant_ref"))

    def owns_removed_account(self, record, account_name: str) -> bool:
        return record["provider"] == self.name and record["name"] == account_name

    def observe(self, home, chat) -> None:
        from tools.connectors.login_handoff import _observe_mcp
        _observe_mcp(home, chat)

    def accepts_server(self, config: dict, url) -> bool:
        return url.scheme == "https" and bool(url.hostname) and config.get("auth") == "oauth"

    def detail(self, config: dict, url) -> str:
        return "Authorize the intended account at " + (url.hostname or "")

    def complete_callback(self, home, chat, record, attempt, params):
        from tui_gateway.mcp_oauth_sessions import deliver_callback_flow
        if record["status"] != "awaiting_human" or not attempt or not attempt.get("oauth"):
            raise ValueError("No active authorization for this chat")
        result = deliver_callback_flow(attempt["oauth"].flow.flow_id, record["name"], **params)
        if not result["ok"]:
            raise ValueError("Provider callback rejected")
        return record, False


class GoogleHandoff(HandoffProvider):
    name = "google-gmail"

    def requires_redirect(self) -> bool:
        return True

    def worker(self):
        from tools.connectors.login_handoff_google import worker as google_worker
        return google_worker

    def release(self, attempt) -> None:
        if not attempt.get("google_gmail"):
            return
        from tools.connectors.google_gmail_login import cancel as cancel_google
        cancel_google(attempt)

    def absorb_cancel(self, home, record, attempt):
        self.release(attempt)

    def account_changed(self, home, record) -> bool:
        import hashlib
        import json
        from hermes_cli.mcp_config import _get_mcp_servers
        from tools.connectors.login_handoff import _mcp_grant_ref
        cfg = _get_mcp_servers().get(record["name"]) or {}
        digest = hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()
        return digest != record["config_ref"] or _mcp_grant_ref(home, record["name"]) != record.get("grant_ref")

    def owns_removed_account(self, record, account_name: str) -> bool:
        return record["provider"] == self.name and record["name"] == account_name

    def accepts_server(self, config: dict, url) -> bool:
        return (config.get("account_instance") or {}).get("provider") == self.name

    def detail(self, config: dict, url) -> str:
        return "Authorize the requested Google account"

    def complete_callback(self, home, chat, record, attempt, params):
        if record["status"] != "awaiting_human" or not attempt:
            raise ValueError("No active Google authorization for this chat")
        from tools.connectors.login_handoff_google import callback as google_callback
        return google_callback(home, chat, record, attempt, params), True


_CODEX = CodexHandoff()
_MCP = McpHandoff()
_GOOGLE = GoogleHandoff()
_BY_NAME = {_MCP.name: _MCP, _GOOGLE.name: _GOOGLE, _CODEX.name: _CODEX}


def provider_for(name: str) -> HandoffProvider:
    return _BY_NAME.get(name, _CODEX)


def provider_for_server(config: dict, url) -> HandoffProvider:
    for provider in (_GOOGLE, _MCP):
        if provider.accepts_server(config, url):
            return provider
    raise ValueError("Chat sign-in requires a configured HTTPS MCP OAuth server")


def providers():
    return (_MCP, _GOOGLE, _CODEX)


def grant_for(home, name: str, config: dict) -> str:
    if _GOOGLE.accepts_server(config, None):
        from tools.connectors.google_gmail_login import grant_ref
        return grant_ref(home, name, config)
    from tools.connectors.login_handoff import _mcp_token_grant
    return _mcp_token_grant(home, name)


def release_attempt(attempt) -> None:
    for provider in providers():
        provider.release(attempt)
    attempt["cancelled"] = True
