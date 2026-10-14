"""One named cron profile. Helpers that receive this must not open another home."""
from __future__ import annotations

import re
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from fastapi import HTTPException

_JOB_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")


@dataclass(frozen=True)
class CronProfileScope:
    """Profile resolved at the mobile route boundary.

    ``home()`` is resolved again on each use so a profile that disappears
    mid-request fails closed instead of falling back to the dashboard home.
    """

    profile: str

    @classmethod
    def bind(cls, job_id: str, profile: str | None) -> CronProfileScope:
        if not profile or not profile.strip() or profile.strip().lower() == "all":
            raise HTTPException(status_code=400, detail="Cron profile scope requires one explicit profile")
        if not _JOB_ID.fullmatch(job_id):
            raise HTTPException(status_code=400, detail="Cron profile scope requires a canonical job id")
        from hermes_cli.web_server_cron import _cron_profile_home

        selected, _home = _cron_profile_home(profile)
        return cls(selected)

    def home(self) -> Path:
        from hermes_cli.web_server_cron import _cron_profile_home

        _selected, home = _cron_profile_home(self.profile)
        return Path(home)

    def output_dir(self, job_id: str) -> Path:
        return self.home() / "cron" / "output" / job_id

    @contextmanager
    def home_scope(self):
        from hermes_constants import (
            get_hermes_home,
            reset_hermes_home_override,
            set_hermes_home_override,
        )

        home = self.home()
        if home.resolve() == get_hermes_home().resolve():
            yield None
            return
        token = set_hermes_home_override(str(home))
        try:
            yield home
        finally:
            reset_hermes_home_override(token)

    def stamp(self, result: dict) -> dict:
        """Owner for the client. This is not a mode flag."""
        return {**result, "profile": self.profile}
