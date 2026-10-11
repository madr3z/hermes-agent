"""A client without a vault prompt must not be reported as a human decline."""

import json

import pytest

from agent.vault_backends import unlock
from agent.vault_store import VaultStore
from tools import browser_vault_tool
from tools.registry import registry
from tui_gateway import server, server_requests


@pytest.mark.parametrize("answerable,reply,expected", [
    (False, None, "prompt_unavailable"),
    (True, {"result": {"value": ""}}, "save_declined"),
    (True, {"error": {"code": -32601, "message": "Unsupported method"}}, "prompt_unavailable"),
])
def test_native_prompt_availability_and_explicit_decline(monkeypatch, tmp_path, answerable, reply, expected):
    store = VaultStore(base_dir=tmp_path / "vault")
    frames = []

    def respond(frame):
        frames.append(frame)
        assert server_requests.resolve_response({"id": frame["id"], **reply})

    monkeypatch.setattr(server_requests, "_answerable", lambda sid: answerable)
    monkeypatch.setattr(server_requests, "_write", respond)
    monkeypatch.setattr(server_requests, "_emit", lambda *args: None)
    monkeypatch.setattr(browser_vault_tool, "_focus_bound_origin", lambda *args: None)
    monkeypatch.setattr(browser_vault_tool, "_current_page_origin", lambda task_id: "https://ticktick.com")
    monkeypatch.setattr(unlock, "can_prompt_here", lambda: True)
    monkeypatch.setattr("agent.vault_store.get_vault_store", lambda: store)
    server._wire_callbacks("phone-session")
    try:
        result = json.loads(registry.dispatch("browser_vault_save_login", {}, task_id="phone-session"))
    finally:
        unlock.set_save_login_prompt_callback(None)
        unlock.set_unlock_prompt_callback(None)
        unlock.set_code_prompt_callback(None)

    assert result["error_type"] == expected
    assert result["success"] is False
    assert bool(frames) is answerable
    assert server_requests.open_request_count() == 0
    assert store.list_items() == []
    if expected == "prompt_unavailable":
        assert "sign-in card" in result["error"]
        assert "user chose" not in result["error"].lower()
