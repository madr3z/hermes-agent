"""The native catalog must report installs from the selected bot profile."""

from pathlib import Path

from tui_gateway import server


def test_catalog_installed_state_uses_selected_profile(tmp_path, monkeypatch):
    from hermes_cli import plugins_cmd_catalog as catalog
    from hermes_cli.plugin_catalog import PluginCatalogEntry

    home = tmp_path / "hermes"
    selected = home / "profiles" / "work"
    (selected / "plugins" / "probe").mkdir(parents=True)
    (home / "profiles" / "other").mkdir(parents=True)
    (selected / "plugins" / "probe" / "plugin.yaml").write_text("name: probe\nversion: 1.0.0\n")
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    entry = PluginCatalogEntry("probe", "https://example.com/probe", "a" * 40, "Probe", "Owner")
    monkeypatch.setattr(catalog, "load_catalog_live", lambda: [entry])
    monkeypatch.setattr(catalog, "resolved_removed_entries", list)

    handler = server._methods["plugins.catalog"]
    work = handler(1, {"profile": "work"})
    other = handler(2, {"profile": "other"})
    assert "error" not in work, work
    assert "error" not in other, other
    assert work["result"]["entries"][0]["installed"] is True
    assert other["result"]["entries"][0]["installed"] is False
    assert work["result"]["entries"][0]["sha"] == "a" * 40
    assert not (home / "config.yaml").exists()
