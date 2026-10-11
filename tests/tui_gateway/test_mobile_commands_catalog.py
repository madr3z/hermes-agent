"""The phone receives bounded support metadata from the canonical command catalog."""

def test_mobile_catalog_distinguishes_native_controls_from_worker_commands(tmp_path, monkeypatch):
    from tui_gateway import server

    monkeypatch.setattr(server, "_sessions", {"ui": {"profile_home": str(tmp_path), "cwd": str(tmp_path)}})
    result = server._methods["commands.catalog"](1, {"session_id": "ui"})["result"]
    meta = result["commands"]
    assert meta["/stop"]["mobile"] == "native"
    assert result["canon"]["/commands"] == "/commands"
    assert any(pair[0] == "/commands" for pair in result["pairs"])
    assert meta["/tasks"]["mobile"] == meta["/agents"]["mobile"] == "native"
    assert meta["/ctx"]["mobile"] == meta["/context"]["mobile"] == "server"
    assert meta["/skills"]["mobile_subcommands"] == ["pending", "approve", "reject", "diff", "approval"]
    assert "install" not in meta["/skills"]["mobile_subcommands"]
    assert meta["/usage"]["mobile_subcommands"] == [""]
    assert meta["/tools"]["mobile_subcommands"] == ["", "list"]
    assert all(meta[key]["mobile"] == "unsupported" for key in ("/reload-mcp", "/snapshot", "/restart", "/new"))


def test_mobile_catalog_discovers_profile_owned_extensions_without_worker_fallback(tmp_path, monkeypatch):
    from agent import skill_commands
    from agent import skill_bundles
    from hermes_cli import plugins
    from tui_gateway import server

    (tmp_path / "config.yaml").write_text("quick_commands:\n  greeting:\n    type: alias\n    target: /status\n")
    monkeypatch.setattr(server, "_sessions", {"ui": {"profile_home": str(tmp_path), "cwd": str(tmp_path)}})
    monkeypatch.setattr(plugins, "get_plugin_commands", lambda: {"plugin-check": {"description": "Check plugin"}})
    monkeypatch.setattr(skill_commands, "get_interactive_skill_commands", lambda: {
        "/review-notes": {"name": "review-notes", "description": "Review notes"}})
    monkeypatch.setattr(skill_bundles, "get_skill_bundles", lambda: {"/daily-bundle": {"description": "Daily bundle"}})
    result = server._methods["commands.catalog"](1, {"session_id": "ui"})["result"]
    assert all(result["commands"][key]["mobile"] == "dispatch"
               for key in ("/greeting", "/plugin-check", "/review-notes", "/daily-bundle"))
    assert result["canon"]["/greeting"] == "/greeting"
