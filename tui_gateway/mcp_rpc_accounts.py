"""Removal of one exact MCP account inside the bound profile."""

import json
import re
from uuid import UUID


def _references(config):
    return set(re.findall(r"\$\{([A-Z][A-Z0-9_]*)\}", json.dumps(config)))


def _owned_slots(name, config, siblings):
    metadata = config.get("account_instance") or {}
    if not metadata:
        return set()  # Legacy shared credential ownership is not inferable from a label.
    instance_id = UUID(metadata["id"])
    if name != "account-" + instance_id.hex:
        raise ValueError("Account ID does not match its credential namespace")
    prefix = f"MCP_ACCOUNT_{instance_id.hex.upper()}_"
    return {slot for slot in _references(config) - _references(siblings) if slot.startswith(prefix)}


def remove_server(rid, params):
    from tui_gateway import server
    from hermes_cli import config as hc, mcp_config as mc
    from hermes_cli.config_write_lock import CONFIG_MUTATION_LOCK
    from hermes_constants import get_hermes_home
    from tools.mcp_oauth_manager import get_manager
    from tools.mcp_tool_common import _core
    from tools.mcp_tool_discovery import _forget_lazy_server
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers
    from tools.mcp_tool_scope import _server_key
    from tui_gateway.mcp_oauth_sessions import cancel_server_flows
    from tools.connectors.login_handoff import cancel_server_requests

    name = server._str_arg(params, "name")
    home = get_hermes_home().resolve()
    with CONFIG_MUTATION_LOCK:
        servers, plugins = server._mcp_server_rows()
        if error := server._mcp_plugin_write_error(rid, name, plugins):
            return error
        if name not in servers:
            return server._err(rid, 4064, f"server '{name}' not found")
        raw = hc.read_raw_config()
        raw_servers = raw.get("mcp_servers") or {}
        selected = raw_servers.pop(name, {})
        slots = _owned_slots(name, selected, {"config": raw, "plugins": {
            key: cfg for key, cfg in servers.items() if plugins[key] is not None}})
        cancel_server_requests(home, name)
        cancel_server_flows(name, str(home))
        shutdown_mcp_servers(scope=_core._mcp_registry_scope(), names={name})
        _forget_lazy_server(_server_key(name))
        get_manager().remove(name, hermes_home=home)
        if selected.get("account_instance", {}).get("provider") == "google-gmail":
            from tools.connectors.google_gmail import remove_gmail_credentials
            remove_gmail_credentials(home, name, selected)
        if not mc._remove_mcp_server(name):
            return server._err(rid, 4064, f"server '{name}' not found")
        for slot in sorted(slots):
            hc.remove_env_value(slot)
    return server._ok(rid, {"ok": True, "removed": True})


def gmail_plan(params):
    """Prepare one read-only Google account. No install, secrets or sign-in side effects."""
    from hermes_constants import get_hermes_home
    from hermes_cli.mcp_config import _get_mcp_servers
    from tools.connectors.google_gmail import gmail_account_plan

    ports = {str((cfg.get("env") or {}).get("WORKSPACE_MCP_PORT", "")) for cfg in _get_mcp_servers().values()}
    port = next((value for value in range(8766, 8866) if str(value) not in ports), None)
    if port is None:
        raise ValueError("No free configured Google callback port. Remove an unused account first.")
    plan = gmail_account_plan(params["label"], params["email"], port,
                              profile_home=get_hermes_home().resolve(), controller_origin=params["controller_origin"])
    return {key: plan[key] for key in ("name", "config", "secret_slots")}
