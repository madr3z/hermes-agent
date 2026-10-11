"""Concurrent account creation must not replace a saved server or bearer credential."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier, BrokenBarrierError

from tui_gateway import server


def test_concurrent_same_name_add_preserves_one_account(tmp_path, monkeypatch):
    from hermes_cli import mcp_config
    import hermes_yaml as yaml

    root = tmp_path / "hermes_home"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    start = Barrier(2)
    saves = Barrier(2)
    original = mcp_config._save_mcp_server

    def paused_save(name, config):
        # On the broken path both creators pass the duplicate check before either saves.
        # Under the write lock only the winner enters; its bounded rendezvous expires.
        try:
            saves.wait(timeout=2)
        except BrokenBarrierError:
            pass
        return original(name, config)

    monkeypatch.setattr(mcp_config, "_save_mcp_server", paused_save)

    def add(index):
        start.wait(timeout=5)
        return server._methods["mcp.servers.add"](index, {
            "name": "icloud-personal", "config": {"command": f"fixture-{index}"},
            "bearer_token": f"fixture-token-{index}",
        })

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(add, index) for index in (1, 2)]
        responses = [future.result(timeout=15) for future in futures]
    successes = [row["result"] for row in responses if "result" in row]
    errors = [row["error"] for row in responses if "error" in row]
    assert len(successes) == 1, responses
    assert [row["code"] for row in errors] == [4090], errors
    saved = yaml.safe_load((root / "config.yaml").read_text())["mcp_servers"]["icloud-personal"]
    assert saved["command"] == successes[0]["server"]["command"]
    winner = saved["command"].split("-")[-1]
    assert f"fixture-token-{winner}" in (root / ".env").read_text()
    assert f"fixture-token-{3 - int(winner)}" not in (root / ".env").read_text()
