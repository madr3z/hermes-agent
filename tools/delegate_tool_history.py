"""Bounded child history in the existing session store. No runtime is restored."""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any

logger = logging.getLogger("tools.delegate_tool")
_RESULT_CHARS = 32000
_HISTORY_ROWS = 100


def session_store_path(agent: Any) -> str:
    """Canonical store identity; profiles can contain equal session IDs."""
    path = getattr(getattr(agent, "_session_db", None), "db_path", None)
    return str(Path(path).resolve()) if isinstance(path, (str, os.PathLike)) else ""


def start_child_history(child: Any, record: dict[str, Any]) -> None:
    """Stamp metadata before the child's first turn creates its session row."""
    metadata = {key: record.get(key) for key in (
        "subagent_id", "parent_id", "depth", "goal", "delegation_id", "model", "started_at", "status",
    )}
    child._subagent_history = metadata
    config = getattr(child, "_session_init_model_config", None)
    if isinstance(config, dict):
        config["_subagent"] = metadata


def finish_child_history(child: Any, entry: dict[str, Any], *, status: str | None = None) -> None:
    """Retain the terminal result independently of the renderer and progress callback."""
    metadata = getattr(child, "_subagent_history", None)
    db = getattr(child, "_session_db", None)
    session_id = getattr(child, "session_id", None)
    if not isinstance(metadata, dict):
        return
    metadata = {**metadata, "status": status or entry.get("status") or "failed", "completed_at": time.time(),
                "summary": str(entry.get("summary") or "")[:_RESULT_CHARS] or None,
                "error": str(entry.get("error") or "")[:_RESULT_CHARS] or None}
    from tools.delegate_tool_registry import _active_subagents, _active_subagents_lock
    with _active_subagents_lock:
        record = _active_subagents.get(metadata["subagent_id"])
        if record is not None and record.get("agent") is child:
            metadata.update({key: record.get(key) for key in ("tool_count", "last_tool")})
            record.update(metadata, accepting_steer=False)
    child._subagent_history = metadata
    config = getattr(child, "_session_init_model_config", None)
    if isinstance(config, dict):
        config["_subagent"] = metadata
    if not db or not isinstance(session_id, str):
        return
    try:
        # Normal turns already created the row. Early failures still need a row for their verdict.
        ensure = getattr(child, "_ensure_db_session", None)
        if callable(ensure):
            ensure()
        db.patch_session_model_config(session_id, {"_subagent": metadata})
    except Exception:
        logger.warning("Failed to persist subagent outcome for %s", session_id, exc_info=True)


def child_history(db: Any, parent_session_id: str) -> list[dict[str, Any]]:
    """Recent children of this conversation, including nested children and compression tips."""
    if db is None or not parent_session_id:
        return []
    lineage = db.get_compression_lineage(parent_session_id) or [parent_session_id]
    marks = ",".join("?" for _ in lineage)
    rows = db._read_all(
        f"""WITH RECURSIVE children(id) AS (
                SELECT id FROM sessions WHERE id IN ({marks})
                UNION
                SELECT s.id FROM sessions s JOIN children p ON s.parent_session_id=p.id
                WHERE json_valid(s.model_config)
                  AND json_extract(s.model_config, '$._subagent.subagent_id') IS NOT NULL
                  AND json_extract(s.model_config, '$._branched_from') IS NULL
                  AND json_extract(s.model_config, '$._reset_from') IS NULL
            )
            SELECT s.id, s.model_config FROM sessions s JOIN children c ON c.id=s.id
            WHERE s.id NOT IN ({marks}) AND json_valid(s.model_config)
              AND json_extract(s.model_config, '$._subagent.subagent_id') IS NOT NULL
            ORDER BY s.started_at DESC LIMIT ?""", (*lineage, *lineage, _HISTORY_ROWS))
    snapshots: dict[str, dict[str, Any]] = {}
    for row in rows:
        metadata = json.loads(row["model_config"])["_subagent"]
        if not isinstance(metadata, dict) or not isinstance(metadata.get("subagent_id"), str):
            continue
        sid = metadata["subagent_id"]
        if sid in snapshots:
            continue
        snapshots[sid] = {**metadata, "child_session_id": row["id"],
                          "accepting_steer": False, "can_steer": False, "can_interrupt": False, "can_tail": False}
    return list(snapshots.values())
