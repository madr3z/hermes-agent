"""Provider-neutral account instances reuse named MCP storage and gateway RPCs."""

import asyncio
from copy import deepcopy
from pathlib import Path

import pytest

from tools.connectors.account_instances import (
    account_instance_params, account_instance_summary, account_secret_slots, resolve_account_instance,
)


def call(method, params):
    from tui_gateway import server

    response = server._methods[method](1, params)
    assert "error" not in response, response
    return response["result"]


def test_oauth_instances_keep_tokens_refresh_removal_and_labels_separate(tmp_path, monkeypatch):
    from hermes_cli.mcp_config import _get_mcp_servers
    from mcp.shared.auth import OAuthToken
    from tools.mcp_oauth import HermesTokenStorage
    from tools.mcp_oauth_manager import get_manager

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    plans = [account_instance_params("custom-oauth", "Same label", {
        "url": "https://fixture.invalid/mcp", "auth": "oauth"}) for _ in range(3)]
    for i, plan in enumerate(plans):
        call("mcp.servers.add", plan)
        storage = HermesTokenStorage(plan["name"], hermes_home=tmp_path)
        asyncio.run(storage.set_tokens(OAuthToken(access_token=f"token-{i}", token_type="Bearer",
                                                 refresh_token=f"refresh-{i}", expires_in=3600)))
    servers = _get_mcp_servers()
    for i, plan in enumerate(plans):
        summary = account_instance_summary(plan["name"], servers[plan["name"]], tmp_path)
        assert resolve_account_instance(servers, summary["account_instance_id"], tmp_path) == plan["name"]
        assert summary["verified_identity"] is None
        token = asyncio.run(HermesTokenStorage(plan["name"], hermes_home=tmp_path).get_tokens())
        assert token.refresh_token == f"refresh-{i}"
    # Refresh/reconnect is scoped to the exact immutable slot, including after a label edit.
    changed = deepcopy(servers[plans[1]["name"]])
    changed["account_instance"]["label"] = "Renamed"
    assert account_instance_summary(plans[1]["name"], changed, tmp_path)["account_instance_id"] == plans[1]["config"]["account_instance"]["id"]
    get_manager().remove(plans[1]["name"], hermes_home=tmp_path)
    call("mcp.servers.remove", {"name": plans[1]["name"]})
    assert asyncio.run(HermesTokenStorage(plans[1]["name"], hermes_home=tmp_path).get_tokens()) is None
    for i in (0, 2):
        token = asyncio.run(HermesTokenStorage(plans[i]["name"], hermes_home=tmp_path).get_tokens())
        assert token.access_token == f"token-{i}"
    with pytest.raises(ValueError, match="missing"):
        resolve_account_instance(_get_mcp_servers(), plans[1]["config"]["account_instance"]["id"], tmp_path)


def test_bearer_instances_use_distinct_existing_secret_slots(tmp_path, monkeypatch):
    from hermes_cli.config import get_env_value
    from hermes_cli.mcp_config import _env_key_for_server, _get_mcp_servers

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    plans = [account_instance_params("custom-token", "API account", {"url": "https://fixture.invalid/mcp"})
             for _ in range(3)]
    for i, plan in enumerate(plans):
        call("mcp.servers.add", {**plan, "bearer_token": f"fixture-{i}"})
    call("mcp.servers.set_api_key", {"name": plans[1]["name"], "value": "replacement-1"})
    assert [get_env_value(_env_key_for_server(plan["name"])) for plan in plans] == [
        "fixture-0", "replacement-1", "fixture-2"]
    assert len({_get_mcp_servers()[plan["name"]]["headers"]["Authorization"] for plan in plans}) == 3
    assert "fixture-" not in (tmp_path / "config.yaml").read_text(encoding="utf-8")


@pytest.mark.parametrize("provider,key", [("custom-stdio", "API_KEY"), ("icloud", "ICLOUD_PASSWORD")])
def test_stdio_and_icloud_instances_reuse_uuid_env_scope(tmp_path, monkeypatch, provider, key):
    from hermes_cli.config import get_env_value, save_env_value
    from hermes_cli.mcp_config import _get_mcp_servers

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    plans = []
    for i in range(3):
        plan = account_instance_params(provider, "Same label", {"command": "/fixture/provider"})
        metadata = plan["config"]["account_instance"]
        refs, secrets = account_secret_slots(metadata["id"], {key: f"fixture-{i}"})
        plan["config"]["env"] = {**refs, "ICLOUD_EMAIL": f"fixture-{i}@icloud.com"} if provider == "icloud" else refs
        for slot, value in secrets.items():
            save_env_value(slot, value)
        call("mcp.servers.add", plan)
        plans.append((plan, secrets))
    saved = _get_mcp_servers()
    import hermes_yaml as yaml

    raw = yaml.safe_load((tmp_path / "config.yaml").read_text(encoding="utf-8"))["mcp_servers"]
    for i, (plan, secrets) in enumerate(plans):
        assert raw[plan["name"]]["env"][key] == "${" + next(iter(secrets)) + "}"
        assert saved[plan["name"]]["env"][key] == f"fixture-{i}"
        assert get_env_value(next(iter(secrets))) == f"fixture-{i}"
    # An explicit local credential removal changes only the selected account.
    from hermes_cli.config import remove_env_value

    remove_env_value(next(iter(plans[1][1])))
    for i in (0, 2):
        assert get_env_value(next(iter(plans[i][1]))) == f"fixture-{i}"


def test_legacy_instance_id_is_stable_without_moving_names_or_trusting_identity(tmp_path):
    config = {"url": "https://fixture.invalid/mcp", "verified_identity": "forged@example.com"}
    first = account_instance_summary("old-name", config, tmp_path / "profile-a")
    assert first == account_instance_summary("old-name", config, tmp_path / "profile-a")
    assert first["account_instance_id"] != account_instance_summary("old-name", config, tmp_path / "profile-b")["account_instance_id"]
    assert first["server_name"] == "old-name" and first["verified_identity"] is None
    assert resolve_account_instance({"old-name": config}, first["account_instance_id"], tmp_path / "profile-a") == "old-name"
