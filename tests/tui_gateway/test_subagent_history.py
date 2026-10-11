"""Delegated work remains visible after reconnect without granting stale controls."""

import json
from types import SimpleNamespace

import pytest


@pytest.fixture
def runtime(tmp_path, monkeypatch):
    from hermes_state import SessionDB
    from tools import delegate_tool_registry as registry
    from tui_gateway import server

    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session(session_id="parent", source="tui", model="test")
    transport = SimpleNamespace(write=lambda frame: True)
    parent = SimpleNamespace(session_id="parent", _session_db=db)
    owner = {"session_key": "parent", "profile_home": str(tmp_path), "agent": parent, "history": [], "transport": transport}
    monkeypatch.setattr(server, "_sessions", {"ui": owner})
    saved = dict(registry._active_subagents)
    registry._active_subagents.clear()

    def call(method="subagent.list", **params):
        return server.dispatch({"id": 1, "method": method, "params": {"session_id": "ui", **params}}, transport=transport)

    yield db, parent, owner, transport, call
    registry._active_subagents.clear()
    registry._active_subagents.update(saved)
    db.close()


def test_completed_child_survives_registry_loss_and_reconnect(runtime):
    from tools.delegate_tool_child_run import _ChildRun, _register_child
    from tools.delegate_tool_registry import _unregister_subagent

    db, parent, owner, transport, call = runtime
    child = SimpleNamespace(_subagent_id="worker", _delegate_depth=1, model="test", session_id="child",
                            _session_db=db, _session_init_model_config={"_delegate_from": "parent"})
    _register_child(child, parent, "Review the code", owner_session_id="ui", owner_transport=transport,
                    owner_session_record=owner)
    db.create_session(session_id="child", source="subagent", model="test", parent_session_id="parent",
                      model_config=child._session_init_model_config)
    entry = {"status": "completed", "summary": "The review passed.", "api_calls": 0}
    _ChildRun(child, parent, 0, "Review the code", "worker", None).emit_complete({}, entry, 1.5)
    terminal = call()["result"]["subagents"][0]
    assert terminal["status"] == "completed" and not terminal["can_interrupt"]
    _unregister_subagent("worker")
    # A reconnect can rebuild the parent AIAgent and UI record from the durable key.
    owner["agent"] = SimpleNamespace(session_id="parent", _session_db=db)
    rows = call()["result"]["subagents"]
    assert len(rows) == 1
    row = rows[0]
    assert (row["subagent_id"], row["child_session_id"], row["status"], row["summary"]) == (
        "worker", "child", "completed", "The review passed.")
    assert row["completed_at"] and not any(row[key] for key in ("can_interrupt", "can_steer", "can_tail"))
    assert not call("subagent.interrupt", subagent_id="worker")["result"]["found"]
    assert call("subagent.steer", subagent_id="worker", text="late")["result"]["status"] == "rejected"


def test_runtime_loss_is_interrupted_and_foreign_profile_is_hidden(runtime, tmp_path):
    from hermes_state import SessionDB
    from tools.delegate_tool_child_run import _register_child

    db, parent, owner, transport, call = runtime
    child = SimpleNamespace(_subagent_id="worker", _delegate_depth=1, model="test", session_id="child",
                            _session_db=db, _session_init_model_config={"_delegate_from": "parent"})
    _register_child(child, parent, "Unfinished work", owner_session_id="ui", owner_transport=transport,
                    owner_session_record=owner)
    db.create_session(session_id="child", source="subagent", model="test", parent_session_id="parent",
                      model_config=child._session_init_model_config)
    live = call()["result"]["subagents"][0]
    assert live["can_interrupt"] and live["can_steer"]
    # A read-only reconnect may not build the parent agent until its next prompt.
    from tui_gateway import server
    server._sessions["ui"] = {**owner, "agent": None}
    lazy = call()["result"]["subagents"][0]
    assert lazy["status"] == "running" and not lazy["can_interrupt"]
    server._sessions["ui"] = owner
    # Same durable IDs in a different profile must not match a live child's lineage.
    foreign = SessionDB(db_path=tmp_path / "foreign" / "state.db")
    foreign.create_session(session_id="parent", source="tui", model="test")
    owner["agent"] = SimpleNamespace(session_id="parent", _session_db=foreign)
    server._sessions["ui"] = {**owner}
    assert call()["result"]["subagents"] == []
    foreign.close()
    owner["agent"] = parent
    server._sessions["ui"] = owner
    from tools.delegate_tool_registry import _active_subagents
    _active_subagents.clear()
    row = call()["result"]["subagents"][0]
    assert row["status"] == "interrupted" and "runtime" in row["error"].lower()
    assert not row["can_interrupt"] and not row["can_steer"]
    assert "_delegate_from" not in json.dumps(row)


def test_nested_failure_history_follows_parent_compression_and_has_no_controls(runtime):
    from tools.delegate_tool_child_run import _ChildRun, _register_child
    from tools.delegate_tool_registry import _active_subagents

    db, parent, owner, transport, call = runtime

    def child(sid, child_id, parent_agent, depth):
        agent = SimpleNamespace(session_id=sid, _subagent_id=child_id, _delegate_depth=depth, model="test",
                                _session_db=db, _parent_subagent_id=getattr(parent_agent, "_subagent_id", None),
                                _session_init_model_config={"_delegate_from": parent_agent.session_id})
        _register_child(agent, parent_agent, sid, owner_session_id="ui", owner_transport=transport, owner_session_record=owner)
        db.create_session(session_id=sid, source="subagent", model="test", parent_session_id=parent_agent.session_id,
                          model_config=agent._session_init_model_config)
        return agent

    middle = child("middle", "worker", parent, 1)
    leaf = child("leaf", "nested", middle, 2)
    entry = {"status": "timeout", "error": "Timed out", "summary": None, "duration_seconds": 1}
    _ChildRun(leaf, middle, 0, "leaf", "nested", None).finish_failed(entry, None, preview="Timed out")
    _active_subagents.clear()
    db.end_session("parent", end_reason="compression")
    db.create_session(session_id="parent-tip", source="tui", model="test", parent_session_id="parent")
    owner["agent"] = SimpleNamespace(session_id="parent-tip", _session_db=db)
    rows = {r["subagent_id"]: r for r in call()["result"]["subagents"]}
    assert rows["nested"]["status"] == "timeout" and rows["nested"]["parent_id"] == "worker"
    assert rows["nested"]["error"] == "Timed out"
    assert rows["worker"]["status"] == "interrupted"
    assert all(not r["can_interrupt"] and not r["can_steer"] for r in rows.values())
