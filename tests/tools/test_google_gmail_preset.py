"""Three account config, refresh and real upstream MCP routing contracts.

Provider tests use --gmail-provider-python, the pinned provider's separate
locked test runtime. Load tests.tools.fixtures.google_gmail_pytest with -p.
They never install it or use a real Google account.
"""

import json
import os
from pathlib import Path
import subprocess

import pytest

from tools.connectors.google_gmail import (
    gmail_account_plan, install_gmail_account, native_callback_redirect, phone_callback_uri,
)

PROBE = Path(__file__).parent / "fixtures" / "google_gmail_provider.py"
PROVIDER_PYTHON = None
EMAILS = [f"fixture-{i}@gmail.com" for i in range(3)]


def plans(tmp_path):
    return [gmail_account_plan(f"gmail-{i}", email, 8711 + i, profile_home=tmp_path)
            for i, email in enumerate(EMAILS)]


def test_explicit_installer_keeps_three_accounts_and_rejects_overwrite(tmp_path, monkeypatch):
    from hermes_cli.mcp_config import _get_mcp_servers

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    accounts = plans(tmp_path)
    for plan in accounts:
        install_gmail_account(plan)
    saved = _get_mcp_servers()
    assert {name: row["env"]["USER_GOOGLE_EMAIL"] for name, row in saved.items()} == {
        plan["name"]: plan["email"] for plan in accounts}
    assert len({p["config"]["env"]["WORKSPACE_MCP_CREDENTIALS_DIR"] for p in accounts}) == 3
    assert len({slot for p in accounts for slot in p["secret_slots"].values()}) == 6
    with pytest.raises(ValueError, match="already exists"):
        install_gmail_account(accounts[0])
    with pytest.raises(ValueError, match="callback port"):
        install_gmail_account(gmail_account_plan("gmail-other", "other@gmail.com", 8711))
    assert _get_mcp_servers() == saved


def test_invalid_account_cannot_escape_its_profile(tmp_path):
    with pytest.raises(ValueError, match="account label"):
        gmail_account_plan("", EMAILS[0], 8711, profile_home=tmp_path)
    with pytest.raises(ValueError, match="full email"):
        gmail_account_plan("gmail", "not-an-email", 8711, profile_home=tmp_path)
    with pytest.raises(ValueError, match="callback port"):
        gmail_account_plan("gmail", EMAILS[0], 80, profile_home=tmp_path)


@pytest.fixture
def provider_accounts(tmp_path, pytestconfig):
    global PROVIDER_PYTHON
    PROVIDER_PYTHON = pytestconfig.getoption("gmail_provider_python", default=None)
    if not PROVIDER_PYTHON:
        pytest.skip("Supply --gmail-provider-python with the pinned provider's isolated Python.")
    accounts = plans(tmp_path)
    for plan in accounts:
        plan["config"]["env"].update({"GOOGLE_OAUTH_CLIENT_ID": "fixture-client",
                                      "GOOGLE_OAUTH_CLIENT_SECRET": "fixture-secret",
                                      "MCP_SINGLE_USER_MODE": "1"})
        run_probe(plan, "seed", plan["email"], "expired")
    return accounts


def provider_env(plan):
    # An allowlist prevents local credentials and provider settings entering the fixture.
    root = Path(plan["config"]["env"]["WORKSPACE_MCP_CREDENTIALS_DIR"]).parents[2]
    return {"PATH": os.environ.get("PATH", ""), "HOME": str(root),
            "HERMES_HOME": str(root), "LANG": "C.UTF-8", **plan["config"]["env"]}


def run_probe(plan, *args):
    result = subprocess.run([PROVIDER_PYTHON, str(PROBE), *args], env=provider_env(plan),
                            capture_output=True, text=True, timeout=30, check=False)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_provider_refresh_revoke_and_foreign_email_are_account_scoped(provider_accounts):
    accounts = provider_accounts
    for plan in accounts:
        assert run_probe(plan, "probe", plan["email"])["token"] == f"access:{plan['email']}"
        assert run_probe(plan, "probe", "unknown@gmail.com")["token"] is None
    untouched = {p["name"]: {f.name: f.read_bytes() for f in Path(
        p["config"]["env"]["WORKSPACE_MCP_CREDENTIALS_DIR"]).glob("*.json")}
        for p in (accounts[0], accounts[2])}
    run_probe(accounts[1], "seed", accounts[1]["email"], "revoked")
    assert run_probe(accounts[1], "probe", accounts[1]["email"])["token"] is None
    for plan in (accounts[0], accounts[2]):
        assert run_probe(plan, "probe", plan["email"])["token"] == f"access:{plan['email']}"
        directory = Path(plan["config"]["env"]["WORKSPACE_MCP_CREDENTIALS_DIR"])
        assert {f.name: f.read_bytes() for f in directory.glob("*.json")} == untouched[plan["name"]]


def test_real_hermes_mcp_dispatch_reaches_the_selected_google_account(provider_accounts):
    from tools.mcp_tool_discovery import register_mcp_servers
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers
    from tools.registry import registry
    from tools.mcp_tool_schema import mcp_prefixed_tool_name

    configs = {}
    for plan in provider_accounts:
        configs[plan["name"]] = {**plan["config"], "command": PROVIDER_PYTHON,
                                 "args": [str(PROBE), "serve", *plan["config"]["args"]],
                                 "env": provider_env(plan), "timeout": 45}
    try:
        registered = register_mcp_servers(configs)
        for plan in provider_accounts:
            tools = registry.get_tool_names_for_toolset(f"mcp-{plan['name']}")
            search = mcp_prefixed_tool_name(plan["name"], "search_gmail_messages")
            assert search in tools
            assert search in registered
            assert not any("send_gmail" in name or "draft_gmail" in name for name in tools)
            handler = registry.get_entry(search).handler
            result = handler({"query": "fixture-query", "user_google_email": plan["email"], "page_size": 1})
            assert f"identity:{plan['email']}" in str(result)
            assert all(f"identity:{email}" not in str(result) for email in EMAILS if email != plan["email"])
            foreign = handler({"query": "fixture-query", "user_google_email": "unknown@gmail.com"})
            assert "identity:" not in str(foreign)
    finally:
        shutdown_mcp_servers(names=set(configs))


def test_google_phone_redirect_is_fixed_and_preserves_state_without_account_selection():
    from urllib.parse import parse_qs, urlparse

    callback = phone_callback_uri("https://private.example.com")
    assert callback == "https://private.example.com/api/connector-callbacks/google"
    redirected = native_callback_redirect("code=fixture-code&state=fixture-state&account=wrong&redirect=https://evil.invalid")
    url = urlparse(redirected)
    assert url.scheme == "com.hermes.iphone" and url.path == "/oauth/callback"
    assert parse_qs(url.query) == {"code": ["fixture-code"], "state": ["fixture-state"]}
    for query in ("code=x", "code=x&state=s&state=other", "code=x&error=denied&state=s"):
        with pytest.raises(ValueError):
            native_callback_redirect(query)
    for origin in ("http://private.example.com", "https://10.0.0.1", "https://main.local"):
        with pytest.raises(ValueError):
            phone_callback_uri(origin)


def test_upstream_phone_callback_uses_https_redirect_pkce_and_google_returned_identity(provider_accounts, tmp_path):
    from tools.connectors.google_gmail_login import begin

    plan = gmail_account_plan("Phone mail", "requested@gmail.com", 8714, profile_home=tmp_path,
                              controller_origin="https://private.example.com")
    plan["config"]["env"].update({"GOOGLE_OAUTH_CLIENT_ID": "fixture-client",
                                  "GOOGLE_OAUTH_CLIENT_SECRET": "fixture-secret"})
    proof = run_probe(plan, "callback-proof", plan["email"], "returned@gmail.com")
    assert proof["users"] == ["returned@gmail.com"]
    native = begin({}, tmp_path, plan["name"], plan["config"],
                   provider_call=lambda name, params: json.dumps({"result": proof["authorization_url"]}))
    assert native["auth_url"] == proof["authorization_url"]
