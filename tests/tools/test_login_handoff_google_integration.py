"""The Google adapter shares the existing durable account/chat continuation guard."""
import json
import time
from urllib.parse import quote

import pytest


def test_google_acceptance_uses_existing_chat_and_pins_the_verified_grant(tmp_path, monkeypatch):
    from hermes_cli.mcp_config import _save_mcp_server
    from tools.connectors import login_handoff as login, google_gmail_login as google
    from tools.connectors.google_gmail import gmail_account_plan
    from tools.connectors.login_handoff_google import verified_identity

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    plan = gmail_account_plan("Work", "work@example.com", 8766, profile_home=tmp_path, controller_origin="https://controller.example")
    assert _save_mcp_server(plan["name"], plan["config"])
    request = login.create_mcp(tmp_path, "owning-chat", plan["name"])
    assert request["provider"] == "google-gmail"
    with login._database(tmp_path) as db:
        record = login._read(db, request["id"], "owning-chat")
        record["expires_at"] = time.time() + 900
        login._write(db, record)
    attempt = {"cancelled": False}
    login._ACTIVE[request["id"]] = attempt
    directory = tmp_path / "connectors/google-gmail" / plan["config"]["account_instance"]["id"]
    path = directory / (quote("work@example.com", safe="@._-") + ".json")
    try:
        def accepted(*args, **kwargs):
            directory.mkdir(parents=True)
            path.write_text('{"token":"synthetic"}')
            return {"verified_identity": "work@example.com", "account_ref": plan["name"],
                    "grant_ref": google.grant_ref(tmp_path, plan["name"], plan["config"])}

        monkeypatch.setattr(google, "complete", accepted)
        with pytest.raises(ValueError):
            login.callback(tmp_path, "other-chat", request["id"], {"state": "synthetic", "code": "synthetic"})
        result = login.callback(tmp_path, "owning-chat", request["id"], {"state": "synthetic", "code": "synthetic"})
        assert result["status"] == "authorized" and result["verified_identity"] == "work@example.com"
        assert verified_identity(tmp_path, plan["name"], plan["config"]) == "work@example.com"
        assert login.continuation(tmp_path, "owning-chat", request["id"])["continued"] is False
        path.write_text('{"token":"changed"}')
        assert verified_identity(tmp_path, plan["name"], plan["config"]) is None
        with pytest.raises(ValueError):
            login.continuation(tmp_path, "owning-chat", request["id"])
    finally:
        login._ACTIVE.pop(request["id"], None)


def test_google_plan_and_removal_keep_sibling_instances(tmp_path, monkeypatch):
    from tui_gateway import server
    from hermes_cli.config import read_raw_config
    from tools.connectors.google_gmail import install_gmail_account, gmail_account_plan

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    first = gmail_account_plan("Same label", "first@example.com", 8766, profile_home=tmp_path, controller_origin="https://controller.example")
    install_gmail_account(first)
    prepared = server._methods["mcp.accounts.gmail.plan"](1, {"label": "Same label", "email": "second@example.com", "controller_origin": "https://controller.example"})["result"]
    assert prepared["config"]["env"]["WORKSPACE_MCP_PORT"] == "8767"
    assert prepared["name"] != first["name"]
    collision = gmail_account_plan("Same label", "collision@example.com", 8766, profile_home=tmp_path, controller_origin="https://controller.example")
    refused = server._methods["mcp.servers.add"](2, {"name": collision["name"], "config": collision["config"]})
    assert refused["error"]["code"] == 4090
    assert set(read_raw_config()["mcp_servers"]) == {first["name"]}
    second = {"name": prepared["name"], "config": prepared["config"]}
    assert "result" in server._methods["mcp.servers.add"](2, second)
    directories = [tmp_path / "connectors/google-gmail" / plan["config"]["account_instance"]["id"] for plan in (first, second)]
    for directory in directories:
        directory.mkdir(parents=True)
        (directory / "fixture@example.com.json").write_text(json.dumps({"token": "synthetic"}))
    result = server._methods["mcp.servers.remove"](3, {"name": first["name"]})
    assert "result" in result, result
    assert not directories[0].exists() and directories[1].exists()
    assert set(read_raw_config()["mcp_servers"]) == {second["name"]}


def test_google_start_registers_only_the_selected_transport(tmp_path, monkeypatch):
    from hermes_cli.mcp_config import _save_mcp_server
    from tools.connectors import login_handoff as login, google_gmail_login as google
    from tools.connectors.google_gmail import gmail_account_plan
    from tools.connectors.login_handoff_google import worker
    from tools.connectors.mcp_oauth import NATIVE_CLIENT_REDIRECT_URI
    import tools.mcp_tool_discovery as discovery

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    plan = gmail_account_plan("Work", "work@example.com", 8766, profile_home=tmp_path, controller_origin="https://controller.example")
    assert _save_mcp_server(plan["name"], plan["config"])
    request = login.create_mcp(tmp_path, "chat", plan["name"])
    attempt = {"cancelled": False}
    login._ACTIVE[request["id"]] = attempt
    registrations = []
    monkeypatch.setattr(discovery, "register_mcp_servers", lambda rows: registrations.append(rows))

    def begin(active, home, name, cfg, **kwargs):
        assert registrations == [{plan["name"]: plan["config"]}]
        assert active is attempt and home == tmp_path and name == plan["name"]
        return {"auth_url": "https://accounts.google.com/synthetic", "scopes": ["gmail.readonly"]}

    monkeypatch.setattr(google, "begin", begin)
    try:
        worker(tmp_path, "chat", request["id"], attempt, NATIVE_CLIENT_REDIRECT_URI)
        assert attempt["auth_url"] == "https://accounts.google.com/synthetic"
        assert login.list_requests(tmp_path, "chat", required=False)[0]["status"] == "awaiting_human"
    finally:
        login._ACTIVE.pop(request["id"], None)
