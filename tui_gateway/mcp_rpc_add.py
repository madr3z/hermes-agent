"""Atomic creation of one profile-owned MCP server."""


def _prepare_config(server, rid, params):
    mc = server._tools_mod("hermes_cli.mcp_config")
    name, preset = server._str_arg(params, "name"), server._str_arg(params, "preset")
    raw = params.get("config")
    config = dict(raw) if isinstance(raw, dict) else {}
    catalog = server._tools_mod("hermes_cli.mcp_catalog")
    entry = None
    if preset and not (config.get("url") or config.get("command")):
        entry = catalog.get_entry(preset)
        if entry is not None:
            for key, value in catalog._build_server_config(entry, install_dir=None).items():
                config.setdefault(key, value)
        else:
            try:
                mc._apply_mcp_preset(name, preset_name=preset, url=config.get("url"),
                                     command=config.get("command"),
                                     cmd_args=list(config.get("args") or []), server_config=config)
            except ValueError:
                return config, entry, server._err(rid, 4063, f"Unknown MCP catalog entry or preset: {preset}")
    if not config.get("url") and not config.get("command"):
        return config, entry, server._err(rid, 4063, "config must specify a 'url' (http) or 'command' (stdio), or a valid 'preset'")
    if metadata := config.get("account_instance"):
        from tools.connectors.account_instances import account_instance_params

        canonical = account_instance_params(metadata["provider"], metadata["label"], config,
                                            account_instance_id=metadata["id"],
                                            requested_identity=metadata.get("requested_identity", ""))
        if canonical["name"] != name:
            return config, entry, server._err(rid, 4063, "Account ID must match its immutable server name")
        config = canonical["config"]
        if metadata["provider"] == "google-gmail":
            from tools.connectors.google_gmail_login import _binding
            from hermes_constants import get_hermes_home
            _binding(get_hermes_home().resolve(), name, config)
            port = config["env"]["WORKSPACE_MCP_PORT"]
            if any(str((cfg.get("env") or {}).get("WORKSPACE_MCP_PORT", "")) == str(port)
                   for cfg in server._mcp_server_rows()[0].values()):
                return config, entry, server._err(rid, 4090, "This Google callback port is already in use. Prepare another account.")
    return config, entry, None


def add_server(rid, params):
    from tui_gateway import server
    from hermes_cli.config_write_lock import CONFIG_MUTATION_LOCK

    mc = server._tools_mod("hermes_cli.mcp_config")
    name = server._str_arg(params, "name")
    # Share the HTTP writer's lock. The loser must not rotate a bearer token before rejection.
    # The RPC decorator already bound home + secrets. Re-entering the dashboard's
    # profile resolver would replace that scope with the dashboard launch profile.
    with CONFIG_MUTATION_LOCK:
        servers, plugins = server._mcp_server_rows()
        if err := server._mcp_plugin_write_error(rid, name, plugins):
            return err
        if name in servers:
            return server._err(rid, 4090, f"server '{name}' already exists")
        config, entry, err = _prepare_config(server, rid, params)
        if err:
            return err
        if bearer_token := params.get("bearer_token"):
            config["headers"] = mc._save_bearer_auth_token(name, str(bearer_token))
        saved_ok = mc._save_mcp_server(name, config)
        saved = mc._get_mcp_servers().get(name, config) if saved_ok else config
    server._tools_mod("tui_gateway.mcp_rpc_helpers").record_mcp_add(entry, config, saved_ok)
    if not saved_ok:
        return server._err(rid, 4001, f"server '{name}' rejected: suspicious command/args configuration")
    return server._ok(rid, {"ok": True, "name": name, "server": server._mcp_summarize_server(name, saved)})
