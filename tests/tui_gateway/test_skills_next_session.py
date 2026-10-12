"""Opt-in hub installs preserve active skill prompt state; legacy callers retain apply-now."""
from pathlib import Path

import pytest

from agent import prompt_builder as pb
from tui_gateway import server as srv


def _write_skill(home, name):
    path = home / "skills" / name / "SKILL.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"---\nname: {name}\ndescription: Synthetic test instructions.\n---\nBody.\n")
    return path


@pytest.fixture
def install_fixture(tmp_path, monkeypatch):
    from hermes_cli import skills_hub
    from tools import skills_sync_bundled_ops
    from hermes_constants import get_hermes_home

    launch, worker = tmp_path / "launch", tmp_path / "worker"
    for home in (launch, worker):
        home.mkdir()
        (home / "config.yaml").write_text("{}\n")
        _write_skill(home, "existing")
    monkeypatch.setenv("HERMES_HOME", str(launch))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setattr(srv, "_hermes_home", launch)
    monkeypatch.setattr(srv, "_profile_home", lambda name: worker if name == "worker" else None)
    monkeypatch.setattr(skills_sync_bundled_ops, "bundled_skill_for_install", lambda name: name)
    monkeypatch.setattr(skills_hub, "_record_skill_install", lambda *args, **kwargs: None)

    def restore(name):
        path = _write_skill(get_hermes_home(), name)
        return {"ok": True, "action": "restored", "path": str(path)}

    monkeypatch.setattr(skills_sync_bundled_ops, "ensure_bundled_skill", restore)
    pb.clear_skills_system_prompt_cache(clear_snapshot=True)
    yield launch, worker
    pb.clear_skills_system_prompt_cache(clear_snapshot=True)


@pytest.mark.parametrize("profile", [None, "worker"])
def test_next_session_install_retains_real_prompt_cache_and_disk_snapshot(install_fixture, profile):
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override

    launch, worker = install_fixture
    home = worker if profile else launch
    token = set_hermes_home_override(home)
    try:
        initial = pb.build_skills_system_prompt()
    finally:
        reset_hermes_home_override(token)
    assert "existing" in initial
    cache = dict(pb._SKILLS_PROMPT_CACHE)
    snapshot = home / ".skills_prompt_snapshot.json"
    frozen = snapshot.read_bytes()
    out = srv._methods["skills.manage"](1, {"profile": profile, "action": "install", "query": "synthetic-new", "next_session": True})
    assert dict(pb._SKILLS_PROMPT_CACHE) == cache
    assert snapshot.read_bytes() == frozen
    assert out["result"] == {"installed": True, "name": "synthetic-new", "activation": "next_session"}
    assert (home / "skills/synthetic-new/SKILL.md").exists()
    other = launch if profile else worker
    assert not (other / "skills/synthetic-new").exists()
    token = set_hermes_home_override(home)
    try:
        assert "synthetic-new" in pb.build_skills_system_prompt()
    finally:
        reset_hermes_home_override(token)


def test_legacy_install_keeps_apply_now_semantics_and_scopes_named_owner(install_fixture):
    launch, worker = install_fixture
    pb.build_skills_system_prompt()
    out = srv._methods["skills.manage"](1, {"profile": "worker", "action": "install", "query": "synthetic-new"})
    assert out["result"] == {"installed": True, "name": "synthetic-new"}
    assert (worker / "skills/synthetic-new/SKILL.md").exists()
    assert not (launch / "skills/synthetic-new").exists()
    assert not pb._SKILLS_PROMPT_CACHE


def test_capability_and_typed_opt_in_are_wire_admitted(install_fixture):
    from tui_gateway.contracts import registry

    result = srv.handle_request({"id": 1, "method": "gateway.capabilities", "params": {"profile": "worker"}})
    assert result["result"]["skills_install_next_session"] is True
    assert registry.METHODS["skills.manage"].params.model_validate(
        {"profile": "worker", "action": "install", "next_session": True}).next_session is True
    for invalid in ("true", 1, None):
        out = srv.handle_request({"id": 2, "method": "skills.manage", "params": {
            "profile": "worker", "action": "install", "query": "invalid", "next_session": invalid}})
        assert out["error"]["code"] == 4000
    out = srv.handle_request({"id": 3, "method": "skills.manage", "params": {"action": "list", "next_session": True}})
    assert out["error"]["code"] == 4000
