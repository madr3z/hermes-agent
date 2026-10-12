"""Session-owned slash controls. The CLI worker has no live queue or idle driver."""

from __future__ import annotations

import sqlite3


_QUEUE_USAGE = "Usage: /queue [list | clear | edit N <prompt> | rm N | move A B | add <prompt>]. Use /queue add <prompt> for text that starts with a management verb."


def _queue_int(value: str) -> int:
    try:
        index = int(value) if value.isdecimal() else 0
    except ValueError:
        raise ValueError(_QUEUE_USAGE) from None
    if index < 1:
        raise ValueError(_QUEUE_USAGE)
    return index


def _queue_args(arg: str) -> tuple[str, list]:
    if not arg:
        return "list", []
    verb, *tail = arg.split(None, 1)
    rest = tail[0].strip() if tail else ""
    verb = {"ls": "list", "show": "list", "set": "edit", "remove": "rm",
            "delete": "rm", "del": "rm", "pop": "rm"}.get(verb.lower(), verb.lower())
    if verb in {"list", "clear"}:
        if rest:
            raise ValueError(_QUEUE_USAGE)
        return verb, []
    if verb == "add":
        if not rest:
            raise ValueError(_QUEUE_USAGE)
        return "send", [rest]
    if verb == "edit":
        fields = rest.split(None, 1)
        if len(fields) != 2:
            raise ValueError(_QUEUE_USAGE)
        return verb, [_queue_int(fields[0]), fields[1]]
    if verb in {"rm", "move"}:
        fields = rest.split()
        if len(fields) != (2 if verb == "move" else 1):
            raise ValueError(_QUEUE_USAGE)
        return verb, [_queue_int(field) for field in fields]
    return "send", [arg]


def _queue_entries(session: dict) -> list[dict]:
    head = session.get("queued_prompt")
    return ([head] if head else []) + list(session.get("queued_prompts") or [])


def _queued_row_change(session: dict, entry: dict, text: str | None) -> None:
    """Update only this pending row, including its recorded pre-compression owner."""
    from tui_gateway import server

    staged = entry.get("_submit_user_row")
    if not isinstance(staged, dict) or not isinstance(staged.get("_row_id"), int):
        return
    if text is not None and not isinstance(staged.get("content"), str):
        raise ValueError("Only text queue entries can be edited. Use /queue rm N and /queue add <prompt>.")
    with server._session_db(session) as db:
        if db is None:
            raise RuntimeError("The queue's session database is unavailable.")
        key = server._submit_row_owner_key(staged, session)
        live_id = db.resolve_active_row_id(key, staged["_row_id"])
        if text is None:
            if live_id is not None and not db.deactivate_message(key, live_id):
                raise RuntimeError("The pending user row could not be canceled.")
        else:
            if live_id is None or not db.set_user_message_content(key, live_id, text):
                raise RuntimeError("The pending user row could not be edited.")
            staged.update(_row_id=live_id, content=text)


def _queue_index(entries: list, index: int) -> int:
    if index > len(entries):
        raise ValueError(f"Queue index {index} is out of range (pending: {len(entries)}). {_QUEUE_USAGE}")
    return index - 1


def _queue_list(entries: list[dict]) -> str:
    if not entries:
        return "No pending prompts. The active turn is not part of the queue."
    lines = ["Pending prompts (excludes the active turn):"]
    for index, entry in enumerate(entries, 1):
        text = entry.get("text")
        shown = text.replace("\n", " ") if isinstance(text, str) else "[structured prompt]"
        images = len(entry.get("image_paths") or [])
        suffix = f" [{images} attachment(s)]" if images else ""
        lines.append(f"{index}. {shown[:160]}{'…' if len(shown) > 160 else ''}{suffix}")
    return "\n".join(lines)


def _queue_mutate(session: dict, verb: str, args: list, removed: list[dict]) -> str:
    from tui_gateway import server

    entries = _queue_entries(session)
    if verb == "list":
        return _queue_list(entries)
    if verb == "move":
        source, destination = (_queue_index(entries, value) for value in args)
        entries.insert(destination, entries.pop(source))
        server._ac_set_queue(session, entries)
        return f"Moved pending prompt {args[0]} to {args[1]}."
    if verb == "edit":
        entry = entries[_queue_index(entries, args[0])]
        if not isinstance(entry.get("text"), str):
            raise ValueError("Only text queue entries can be edited. Use /queue rm N and /queue add <prompt>.")
        _queued_row_change(session, entry, args[1])
        entry["text"] = args[1]
        return f"Edited pending prompt {args[0]}."
    # Install each successful cancellation before the next database operation. A failed clear
    # retains every uncanceled envelope and reports the completed count without reviving rows.
    indices = [args[0]] if verb == "rm" else [1] * len(entries)
    for index in indices:
        position = _queue_index(entries, index)
        entry = entries[position]
        _queued_row_change(session, entry, None)
        removed.append(entries.pop(position))
        server._ac_set_queue(session, entries)
    return f"Canceled {len(removed)} pending prompt(s)."


def dispatch_queue(rid, params: dict, session: dict | None, arg: str) -> dict:
    from tui_gateway import server

    if not session or not session.get("session_key"):
        return server._err(rid, 4001, "No active session queue.")
    try:
        verb, args = _queue_args((arg or "").strip())
    except ValueError as exc:
        return server._err(rid, 4004, str(exc))
    if verb == "send":
        return server._ok(rid, {"type": "send", "message": args[0]})
    removed: list[dict] = []
    with server._session_profile_runtime_scope(session):
        try:
            with session["history_lock"]:
                if session.get("_closing"):
                    return server._err(rid, 4001, "Session is closing.")
                output = _queue_mutate(session, verb, args, removed)
            result = server._exec_out(rid, output)
        except ValueError as exc:
            result = server._err(rid, 4004, str(exc))
        except (RuntimeError, sqlite3.Error) as exc:
            result = server._err(rid, 5031, f"Queue change failed after {len(removed)} cancellation(s): {exc}")
        for entry in removed:
            if token := entry.get("client_turn_id"):
                # The live turn must keep its inflight state, crash marker, and cached prefix.
                server._emit("message.complete", params["session_id"], {
                    "text": "Queued prompt canceled.", "status": "error", "error": "Queued prompt canceled.",
                    "recoverable": False, "client_turn_id": token,
                })
        return result


def _heartbeat_command(key: str, arg: str) -> str:
    from hermes_cli.heartbeat import HeartbeatManager, MIN_INTERVAL_SECONDS, format_interval, parse_interval

    manager = HeartbeatManager(session_id=key)
    lower = arg.lower()
    if not arg or lower == "status":
        return manager.status_line()
    actions = {"pause": manager.pause, "resume": manager.resume,
               "clear": manager.clear, "stop": manager.clear, "off": manager.clear}
    if lower in actions:
        actions[lower]()
        return manager.status_line()
    fields = arg.split(None, 1)
    if fields[0].lower() == "every":
        fields = fields[1].split(None, 1) if len(fields) == 2 else []
    interval = parse_interval(fields[0]) if fields else None
    if interval is None or interval < 0 or len(fields) != 2:
        raise ValueError(f"Usage: /heartbeat every <interval> <prompt> | status | pause | resume | clear. Interval must be at least {MIN_INTERVAL_SECONDS}s.")
    state = manager.set(fields[1], interval)
    return f"Heartbeat set (every {format_interval(state.interval_seconds)}): {state.prompt}"


def _subgoal_command(key: str, arg: str) -> str:
    from hermes_cli.goals import GoalManager

    manager = GoalManager(session_id=key)
    if not manager.has_goal():
        raise ValueError("No active goal. Set one with /goal before adding subgoals.")
    if not arg:
        return manager.status_line() + "\n" + manager.render_subgoals()
    verb, *rest = arg.split(None, 1)
    if verb.lower() == "remove":
        if not rest or not rest[0].isdecimal():
            raise ValueError("Usage: /subgoal remove N (1-based).")
        index = int(rest[0])
        if index < 1:
            raise ValueError("Usage: /subgoal remove N (1-based).")
        return f"Removed subgoal {index}: {manager.remove_subgoal(index)}"
    if verb.lower() == "clear":
        if rest:
            raise ValueError("Usage: /subgoal clear")
        return f"Cleared {manager.clear_subgoals()} subgoal(s)."
    return f"Added subgoal: {manager.add_subgoal(arg)}"


def _loop_command(key: str, arg: str) -> str:
    from tui_gateway import server

    loops = server._tools_mod("hermes_cli.loops")
    result = loops.dispatch_loop_command(loops.LoopManager(session_id=key), arg)
    output = result.get("output") or ""
    if result.get("created") and loops.goal_blocks_loop_tick(key):
        output += ("\nNote: an active /goal is driving this session — loop "
                   "wakeups defer until the goal finishes, pauses, or parks.")
    return output


def dispatch_control(rid, session: dict | None, name: str, arg: str) -> dict:
    from tui_gateway import server

    if not session or not (key := session.get("session_key")):
        return server._err(rid, 4001, "No active stored session.")
    handlers = {"heartbeat": _heartbeat_command, "subgoal": _subgoal_command, "loop": _loop_command}
    with server._session_profile_runtime_scope(session):
        try:
            with session["history_lock"]:
                if session.get("_closing"):
                    return server._err(rid, 4001, "Session is closing.")
                output = handlers[name](key, (arg or "").strip())
        except (ValueError, RuntimeError, IndexError) as exc:
            return server._err(rid, 4004, f"/{name}: {exc}")
    return server._exec_out(rid, output)
