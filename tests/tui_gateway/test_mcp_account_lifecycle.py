"""Real profile-owned account RPCs retain sibling and legacy credentials."""

from uuid import uuid4

from tui_gateway import server
from tools.connectors.account_instances import account_instance_params


def call(method, params):
    return server._methods[method](1, params)


def test_account_labels_do_not_choose_credentials(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    first = account_instance_params("custom-mcp", "Work", {"url": "https://example.com/mcp"}, requested_identity="requested@example.com")
    second = account_instance_params("custom-mcp", "Work", {"url": "https://example.com/mcp"})
    for request in (first, second):
        assert "result" in call("mcp.servers.add", request)
    rows = call("mcp.servers.list", {})["result"]["servers"]
    assert {row["label"] for row in rows} == {"Work"}
    assert len({row["account_instance_id"] for row in rows}) == 2
    assert all(row["verified_identity"] is None for row in rows)
    wrong = account_instance_params("custom-mcp", "Other", {"command": "fixture"})
    wrong["name"] = "different-namespace"
    assert "error" in call("mcp.servers.add", wrong)


def test_remove_deletes_only_owned_account_secrets_and_oauth(tmp_path, monkeypatch):
    from hermes_cli import config
    from tools.mcp_oauth import HermesTokenStorage
    from tools.mcp_oauth_manager import get_manager
    from tools.mcp_tool_common import _core
    from tools.mcp_tool_scope import _server_key

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    account_id = uuid4()
    owned = f"MCP_ACCOUNT_{account_id.hex.upper()}_PASSWORD"
    shared = f"MCP_ACCOUNT_{account_id.hex.upper()}_SHARED"
    request = account_instance_params("custom-mcp", "Personal", {"command": "fixture", "env": {
        "PASSWORD": "${" + owned + "}", "SHARED": "${" + shared + "}"}}, account_instance_id=str(account_id))
    name = request["name"]
    assert "result" in call("mcp.servers.add", request)
    assert "result" in call("mcp.servers.add", {"name": "legacy", "config": {"command": "fixture", "env": {"KEY": "${" + shared + "}"}}})
    for slot in (owned, shared, "UNRELATED_KEY"):
        config.save_env_value(slot, "fixture-value")
    storage = HermesTokenStorage(name, hermes_home=tmp_path)
    storage._tokens_path().parent.mkdir(parents=True, exist_ok=True)
    storage._tokens_path().write_text('{"access_token":"fixture-token"}')
    sibling = HermesTokenStorage("legacy", hermes_home=tmp_path)
    sibling._tokens_path().parent.mkdir(parents=True, exist_ok=True)
    sibling._tokens_path().write_text('{"access_token":"sibling-token"}')
    key = _server_key(name)
    _core._lazy_server_configs[key] = request["config"]
    try:
        result = call("mcp.servers.remove", {"name": name})
        assert "result" in result, result
        assert owned not in config.load_env()
        assert shared in config.load_env() and "UNRELATED_KEY" in config.load_env()
        assert not storage._tokens_path().exists()
        assert sibling._tokens_path().exists()
        assert key not in _core._lazy_server_configs
        rows = call("mcp.servers.list", {})["result"]["servers"]
        assert [row["name"] for row in rows] == ["legacy"]
    finally:
        _core._lazy_server_configs.pop(key, None)
        get_manager().evict(name, hermes_home=tmp_path)
