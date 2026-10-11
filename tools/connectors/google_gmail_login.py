"""Workspace MCP's Google consent adapter for the existing login-handoff lifecycle.

The lifecycle owns attempts, locks, cancellation, expiry and continuation. This
adapter keeps transient Google state in that existing attempt, never in chat.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from pathlib import Path
import re
import time
from urllib.parse import parse_qs, quote, urlparse

from tools.connectors.google_gmail import PROVIDER_ARGS, PROVIDER_COMMAND, phone_callback_uri

GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
ISSUER = "https://accounts.google.com"


def _fingerprint(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()


def _binding(home: Path, name: str, config: dict) -> dict:
    from uuid import UUID

    metadata = config.get("account_instance") or {}
    instance_id = str(UUID(metadata["id"]))
    env = config.get("env") or {}
    expected = metadata.get("requested_identity", "").strip().lower()
    directory = Path(env.get("WORKSPACE_MCP_CREDENTIALS_DIR", ""))
    owned_directory = home.resolve() / "connectors" / "google-gmail" / instance_id
    if (metadata.get("provider") != "google-gmail" or name != "account-" + UUID(instance_id).hex
            or config.get("command") != PROVIDER_COMMAND or config.get("args") != PROVIDER_ARGS
            or directory.resolve() != owned_directory
            or not expected or env.get("USER_GOOGLE_EMAIL", "").lower() != expected):
        raise ValueError("The Google account configuration does not match its owning account.")
    redirect = env.get("GOOGLE_OAUTH_REDIRECT_URI", "")
    origin = urlparse(redirect)
    if redirect != phone_callback_uri(f"{origin.scheme}://{origin.netloc}"):
        raise ValueError("Register the private controller's exact Google HTTPS callback first.")
    port = int(env.get("WORKSPACE_MCP_PORT", "0"))
    if not 1024 <= port <= 65535:
        raise ValueError("The Google account has no valid callback listener port.")
    return {"home": str(home.resolve()), "name": name, "config_ref": _fingerprint(config),
            "email": expected, "directory": str(directory), "redirect_uri": redirect, "port": port}


def _credential_files(directory: Path) -> dict[str, bytes]:
    return {path.name: path.read_bytes() for path in directory.glob("*.json")
            if "@" in path.name and path.is_file() and not path.is_symlink()}


def _rollback(binding, snapshot):
    directory = Path(binding["directory"])
    for filename in _credential_files(directory).keys() - snapshot.keys():
        (directory / filename).unlink()
    for filename, contents in snapshot.items():
        path = directory / filename
        path.write_bytes(contents)
        path.chmod(0o600)


def _authorization_text(result) -> str:
    if hasattr(result, "content"):
        return "\n".join(getattr(block, "text", "") for block in result.content)
    if isinstance(result, str):
        try:
            payload = json.loads(result)
        except json.JSONDecodeError:
            return result
        return payload.get("result", "") if isinstance(payload, dict) else ""
    return ""


def _disconnect(name):
    from tools import mcp_tool
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers

    shutdown_mcp_servers(scope=mcp_tool._mcp_registry_scope(), names={name})


def begin(attempt: dict, home: Path, name: str, config: dict, *, provider_call=None,
          now=None, expires_at=None) -> dict:
    """Start consent in one named provider process. Return native-only URL/scopes.

    Call while holding the existing lifecycle lock and checking its active owner.
    The caller must NOT put this return value into a model tool result.
    """
    if attempt.get("cancelled"):
        raise ValueError("This sign-in attempt was cancelled.")
    binding = _binding(home, name, config)
    clock = time.time() if now is None else now
    if provider_call is None:
        from tools.mcp_tool_handlers import _make_tool_handler

        provider_call = lambda target, arguments: _make_tool_handler(target, "start_google_auth", 45)(arguments)
    result = provider_call(name, {"service_name": "Gmail", "user_google_email": binding["email"]})
    urls = re.findall(r"https://accounts\.google\.com/[^\s<>\"`]+", _authorization_text(result))
    valid = []
    for url in urls:
        parsed = urlparse(url)
        params = parse_qs(parsed.query)
        if (parsed.hostname == "accounts.google.com" and not parsed.username and not parsed.fragment
                and params.get("redirect_uri") == [binding["redirect_uri"]]
                and len(params.get("state", [])) == 1 and len(params["state"][0]) >= 16
                and GMAIL_SCOPE in params.get("scope", [""])[0].split()
                and params.get("code_challenge_method") == ["S256"]):
            valid.append((url, params))
    if len(valid) != 1:
        raise ValueError("Google did not return one account-scoped PKCE consent URL.")
    url, params = valid[0]
    attempt["google_gmail"] = {**binding, "state": params["state"][0], "used": False,
                               "expires_at": min(expires_at or clock + 900, clock + 900),
                               "snapshot": _credential_files(Path(binding["directory"]))}
    return {"auth_url": url, "scopes": params["scope"][0].split()}


def _check(attempt, home, name, config, now):
    binding = attempt.get("google_gmail")
    if (not binding or attempt.get("cancelled") or binding["used"]
            or now >= binding["expires_at"] or _binding(home, name, config)["config_ref"] != binding["config_ref"]
            or str(home.resolve()) != binding["home"] or name != binding["name"]):
        raise ValueError("This sign-in attempt is expired, used, cancelled or belongs to another account.")
    return binding


def _callback_get(url, params):
    import httpx

    with httpx.Client(trust_env=False, follow_redirects=False, timeout=45) as client:
        # Upstream's loopback uvicorn listener trusts proxy headers from loopback.
        # OAuthlib must see the original HTTPS scheme while exchanging with the
        # separately configured, exact Google redirect URI.
        response = client.get(url, params=params, headers={"X-Forwarded-Proto": "https"})
        return response.status_code


def _userinfo(token):
    import httpx

    with httpx.Client(trust_env=False, follow_redirects=False, timeout=30) as client:
        response = client.get("https://www.googleapis.com/oauth2/v2/userinfo",
                              headers={"Authorization": "Bearer " + token})
        response.raise_for_status()
        return response.json()


def complete(attempt: dict, home: Path, name: str, config: dict, params: dict, *,
             callback_get=None, userinfo=None, disconnect=None, now=None) -> dict:
    """Relay once to the exact provider process, then verify Google's identity.

    The existing lifecycle MUST hold its cancellation/commit lock throughout
    this call and confirm that this is still its active attempt before calling.
    Only the fixed nonsecret result may be stored in its durable record.
    """
    binding = _check(attempt, home, name, config, time.time() if now is None else now)
    state = params.get("state", "")
    if not isinstance(state, str) or not hmac.compare_digest(state, binding["state"]):
        raise ValueError("Google callback state does not match this account.")
    if params.get("iss") not in (None, "", ISSUER):
        raise ValueError("Google callback issuer does not match.")
    if bool(params.get("code")) == bool(params.get("error")):
        raise ValueError("Google callback must contain one code or error.")
    binding["used"] = True
    if params.get("error"):
        raise ValueError("Google sign-in was declined.")
    try:
        status = (callback_get or _callback_get)(f"http://127.0.0.1:{binding['port']}/oauth2callback",
                                                  {key: params[key] for key in ("code", "state", "iss") if params.get(key)})
        if status != 200 or attempt.get("cancelled"):
            raise ValueError("Google callback was rejected.")
        path = Path(binding["directory"]) / (quote(binding["email"], safe="@._-") + ".json")
        current = _credential_files(path.parent)
        if set(current) != {path.name} or current[path.name] == binding["snapshot"].get(path.name):
            raise ValueError("Google did not save a fresh grant for the requested account.")
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
        identity = (userinfo or _userinfo)(payload["token"])
        if (identity.get("email", "").lower() != binding["email"] or identity.get("verified_email") is not True
                or GMAIL_SCOPE not in payload.get("scopes", []) or not payload.get("refresh_token")
                or attempt.get("cancelled")
                or (time.time() if now is None else now) >= binding["expires_at"]):
            raise ValueError("Google account identity or permissions do not match.")
        binding["accepted"] = True
        return {"verified_identity": binding["email"], "account_ref": name,
                "grant_ref": hashlib.sha256(path.read_bytes()).hexdigest()}
    except Exception:  # health: allow BLE001 -- Provider exceptions may expose credentials; restore only this account and return fixed text.
        (disconnect or _disconnect)(name)
        _rollback(binding, binding["snapshot"])
        raise ValueError("Google sign-in failed or used a different account. No new local grant was accepted.") from None


def cancel(attempt: dict, *, disconnect=None) -> None:
    """Invalidate provider state in its exact process under the lifecycle lock."""
    attempt["cancelled"] = True
    binding = attempt.get("google_gmail")
    if binding and not binding.get("accepted"):
        binding["used"] = True
        (disconnect or _disconnect)(binding["name"])
        _rollback(binding, binding["snapshot"])


def grant_ref(home: Path, name: str, config: dict) -> str:
    """The existing continuation guard can pin the accepted Google grant."""
    binding = _binding(home, name, config)
    path = Path(binding["directory"]) / (quote(binding["email"], safe="@._-") + ".json")
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else ""
