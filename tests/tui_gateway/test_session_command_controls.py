"""Session command controls use the live queue and persisted owned managers."""

import copy
import os
import threading

import pytest

from hermes_state import SessionDB
from tui_gateway import server


@pytest.fixture
def owned_session(tmp_path, monkeypatch):
    home = tmp_path / "owner"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    monkeypatch.setattr(server, "_hermes_home", home)
    db = SessionDB(db_path=home / "state.db")
    db.create_session("stored-owner", "desktop")
    monkeypatch.setattr(server, "_get_db", lambda: db)
    events = []
    monkeypatch.setattr(server, "_emit", lambda *args: events.append(args))
    session = {"session_key": "stored-owner", "history_lock": threading.Lock(),
               "history": [{"role": "user", "content": "cached prefix"}], "running": True,
               "inflight_turn": {"user": "active", "assistant": "ongoing", "status": "streaming"},
               "_submit_user_row": {"content": "active"}, "agent": None}
    server._sessions["owned-command"] = session
    yield session, db, events
    server._sessions.pop("owned-command", None)
    db.close()
    from hermes_cli import goals
    goals._DB_CACHE.clear()


def command(name, arg="", **params):
    return server._methods["command.dispatch"](81, {"session_id": "owned-command", "name": name, "arg": arg, **params})


def enqueue(session, db, text, token):
    entry = server._enqueue_prompt(session, text, object(), image_paths=["/tmp/owned-image"],
                                   turn_author={"name": "Owner"}, client_turn_id=token)
    row = db.append_message("stored-owner", "user", content=text)
    entry["_submit_user_row"] = {"_row_id": row, "content": text, "_submit_row_session_id": "stored-owner"}
    return entry


@pytest.mark.parametrize("arg", ["list extra", "clear the logs", "rm", "rm -1", "rm 1 extra", "edit config",
                                 "edit 1", "move 1", "move 1 2 extra", "add", "show extra", "set config", "delete file", "pop"])
def test_reserved_queue_arguments_never_submit_model_prompts(owned_session, arg):
    result = command("queue", arg)
    assert "error" in result, result
    assert "add" in result["error"]["message"]


def test_queue_inspection_and_mutation_preserve_live_turn_and_durable_identity(owned_session):
    session, db, events = owned_session
    first = enqueue(session, db, "first", "task-first")
    second = enqueue(session, db, "second", "task-second")
    prefix = copy.deepcopy(session["history"])
    inflight = copy.deepcopy(session["inflight_turn"])
    staged = session["_submit_user_row"]
    # The accept-time row remains owned by the old key after a compression rotation.
    session["session_key"] = "rotated-owner"
    listed = command("queue")["result"]
    assert listed["type"] == "exec"
    assert "1. first" in listed["output"] and "2. second" in listed["output"]
    assert command("queue", "move 2 1")["result"]["type"] == "exec"
    assert session["queued_prompt"] is second
    assert command("queue", "edit 1 revised caption")["result"]["type"] == "exec"
    assert second["text"] == second["_submit_user_row"]["content"] == "revised caption"
    assert second["image_paths"] == ["/tmp/owned-image"]
    assert second["turn_author"] == {"name": "Owner"}
    assert second["client_turn_id"] == "task-second"
    assert "revised caption" in str(db.get_messages_as_conversation("stored-owner"))
    assert command("queue", "rm 1")["result"]["type"] == "exec"
    assert session["queued_prompt"] is first
    assert "revised caption" not in str(db.get_messages_as_conversation("stored-owner"))
    assert command("queue", "clear")["result"]["type"] == "exec"
    assert session["queued_prompt"] is None
    assert db.get_messages_as_conversation("stored-owner") == []
    completions = [payload for name, _, payload in events if name == "message.complete"]
    assert {p["client_turn_id"] for p in completions} == {"task-first", "task-second"}
    assert all(p["status"] == "error" for p in completions)
    assert session["inflight_turn"] == inflight
    assert session["history"] == prefix and session["_submit_user_row"] is staged
    assert session["running"] is True and "_queued_prompt_generation" not in session


def test_plain_queue_send_and_explicit_add_keep_the_existing_send_contract(owned_session):
    assert command("queue", "ordinary prompt")["result"] == {"type": "send", "message": "ordinary prompt"}
    assert command("q", "add clear the logs")["result"] == {"type": "send", "message": "clear the logs"}


def test_queue_edit_failure_keeps_the_accepted_prompt(owned_session, monkeypatch):
    session, db, _ = owned_session
    entry = enqueue(session, db, "accepted", "task")
    def fail(*args):
        raise RuntimeError("test store unavailable")
    monkeypatch.setattr(db, "set_user_message_content", fail)
    assert "error" in command("queue", "edit 1 changed")
    assert entry["text"] == entry["_submit_user_row"]["content"] == "accepted"


def test_partial_clear_reports_completed_cancellations_and_retains_remaining_rows(owned_session, monkeypatch):
    session, db, events = owned_session
    enqueue(session, db, "first", "task-first")
    second = enqueue(session, db, "second", "task-second")
    deactivate = db.deactivate_message
    calls = []
    def fail_second(*args):
        calls.append(args)
        if len(calls) == 2:
            raise RuntimeError("test write failed")
        return deactivate(*args)
    monkeypatch.setattr(db, "deactivate_message", fail_second)
    result = command("queue", "clear")
    assert "after 1 cancellation" in result["error"]["message"]
    assert session["queued_prompt"] is second
    assert [row["content"] for row in db.get_messages_as_conversation("stored-owner")] == ["second"]
    assert [payload["client_turn_id"] for name, _, payload in events if name == "message.complete"] == ["task-first"]


def test_controls_bind_session_profile_and_catalog_enables_canonical_commands(owned_session, tmp_path):
    session, _, _ = owned_session
    secondary = tmp_path / "secondary"
    secondary.mkdir()
    (secondary / ".env").write_text("", encoding="utf-8")
    session["profile_home"] = str(secondary)
    environment = dict(os.environ)
    assert command("heartbeat", "every 10m Owned check", profile="ignored-foreign")["result"]["type"] == "exec"
    from hermes_cli.heartbeat import HeartbeatManager
    assert not HeartbeatManager("stored-owner").has_heartbeat()
    with server._session_profile_runtime_scope(session):
        assert HeartbeatManager("stored-owner").state.prompt == "Owned check"
        assert not HeartbeatManager("foreign-session").has_heartbeat()
    assert os.environ == environment
    meta = server._methods["commands.catalog"](83, {"session_id": "owned-command"})["result"]["commands"]
    for name in ("/heartbeat", "/hb", "/loop", "/proactive", "/subgoal"):
        assert meta[name]["mobile"] == "server"


def test_owned_session_controls_use_existing_managers_without_worker_or_prompt(owned_session, monkeypatch):
    session, _, _ = owned_session
    monkeypatch.setattr(server, "_SlashWorker", lambda *a, **kw: pytest.fail("private CLI worker must not own controls"))
    from hermes_cli.goals import GoalManager
    from hermes_cli.heartbeat import HeartbeatManager
    from hermes_cli.loops import LoopManager
    GoalManager("stored-owner").set("Owned goal")
    for text in ["/subgoal Check result", "/heartbeat every 10m Check progress", "/loop 10m Check again"]:
        result = server._methods["slash.exec"](82, {"session_id": "owned-command", "command": text})
        assert result.get("result", {}).get("type") == "exec", result
    assert GoalManager("stored-owner").state.subgoals == ["Check result"]
    assert HeartbeatManager("stored-owner").state.prompt == "Check progress"
    assert LoopManager("stored-owner").state.prompt == "Check again"
    assert "wakeups defer" in command("loop", "10m Owned loop")["result"]["output"]
    assert GoalManager("unrelated").state is None
    assert session["history"] == [{"role": "user", "content": "cached prefix"}]
    for name, arg in [("subgoal", "remove 1"), ("heartbeat", "pause"), ("heartbeat", "resume"),
                      ("heartbeat", "clear"), ("loop", "pause"), ("loop", "resume"), ("loop", "stop")]:
        assert command(name, arg)["result"]["type"] == "exec"
    assert GoalManager("stored-owner").state.subgoals == []
    assert not HeartbeatManager("stored-owner").has_heartbeat()
    assert not LoopManager("stored-owner").has_loop()
