"""Opt-in mobile cron calls never borrow another profile's job or history."""

from pathlib import Path

import pytest
from fastapi import FastAPI
from starlette.testclient import TestClient

from hermes_cli import profiles
from hermes_cli import web_server_cron as helpers
from hermes_cli.web_routers import cron as routes
from hermes_state import SessionDB


@pytest.fixture()
def homes(tmp_path, monkeypatch):
    default = tmp_path / ".hermes"
    worker = default / "profiles" / "worker"
    for home in (default, worker):
        (home / "cron").mkdir(parents=True)
        (home / "config.yaml").write_text("model: fixture\n")
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(default))
    monkeypatch.setattr(profiles, "_get_default_hermes_home", lambda: default)
    monkeypatch.setattr(profiles, "_get_profiles_root", lambda: default / "profiles")
    monkeypatch.setattr(helpers, "_notify_cron_provider_for_profile", lambda _profile: None)
    return {"default": default, "worker": worker}


@pytest.fixture()
def client():
    app = FastAPI()
    app.include_router(routes.router)
    return TestClient(app)


def create(profile, prompt):
    from cron import jobs

    _, home = helpers._cron_profile_home(profile)
    with helpers._cron_store_scope(home):
        return jobs.create_job(prompt=prompt, schedule="every 1h")


def strict(profile):
    return {"profile": profile, "strict_profile": "true"}


def test_detail_edit_trigger_ack_and_wrong_profile_are_scoped(homes, client, monkeypatch):
    job = create("worker", "original full instructions")
    path = f"/api/cron/jobs/{job['id']}"
    fired = []
    monkeypatch.setattr(helpers, "_fire_cron_job_for_profile", lambda profile, job_id, **kw: fired.append((profile, job_id, kw)) or True)
    for method, suffix, body in (("GET", "", None), ("PUT", "", {"updates": {"prompt": "wrong"}}), ("POST", "/trigger", {})):
        response = client.request(method, path + suffix, params=strict("default"), json=body)
        assert response.status_code == 404
    assert fired == []
    detail = client.get(path, params=strict("worker")).json()
    assert "strict_profile" not in detail and detail["profile"] == "worker"
    assert detail["prompt"] == "original full instructions"
    edited = client.put(path, params=strict("worker"), json={"updates": {"prompt": "changed"}})
    assert edited.status_code == 200
    assert edited.json()["profile"] == "worker" and "strict_profile" not in edited.json()
    assert edited.json()["prompt"] == "changed"
    assert edited.json()["schedule"] == detail["schedule"]
    triggered = client.post(path + "/trigger", params=strict("worker"), json={})
    assert triggered.status_code == 200
    assert "strict_profile" not in triggered.json() and triggered.json()["profile"] == "worker"
    assert fired == [("worker", job["id"], {"force": False})]
    legacy = client.get(path, params={"profile": "default"})
    assert legacy.status_code == 200 and legacy.json()["profile"] == "worker"
    assert "strict_profile" not in legacy.json()


def test_deleted_job_history_uses_only_selected_profile_and_stamps_all_rows(homes, client):
    job = create("worker", "deleted definition")
    job_id = job["id"]
    helpers._call_cron_for_profile("worker", "remove_job", job_id)
    for profile, home in homes.items():
        db = SessionDB(db_path=home / "state.db")
        db.create_session(f"cron_{job_id}_20261010_010000", source="cron")
        db.close()
        output = home / "cron" / "output" / job_id
        output.mkdir(parents=True)
        (output / "2026-10-09_00-00-00.md").write_text(f"{profile} script output")
    for profile in homes:
        response = client.get(f"/api/cron/jobs/{job_id}/runs", params={**strict(profile), "limit": 1000})
        assert response.status_code == 200
        payload = response.json()
        assert "strict_profile" not in payload and payload["profile"] == profile
        assert payload["limit"] == 100
        assert {row["source"] for row in payload["runs"]} == {"cron", "cron_output"}
        assert all(row["profile"] == profile for row in payload["runs"])
        assert any(row.get("preview") == f"{profile} script output" for row in payload["runs"])
    assert client.get(f"/api/cron/jobs/{job_id}", params=strict("worker")).status_code == 404


@pytest.mark.parametrize("profile", [None, "", "all", "missing"])
def test_strict_requires_one_existing_explicit_profile(homes, client, profile):
    params = {"strict_profile": "true"}
    if profile is not None:
        params["profile"] = profile
    for suffix in ("", "/runs"):
        response = client.get("/api/cron/jobs/synthetic" + suffix, params=params)
        assert response.status_code in (400, 404)


def test_job_removed_during_resolution_never_scans_another_profile(homes, client, monkeypatch):
    job = create("worker", "remove before write")
    original = helpers._call_cron_for_profile
    seen = []

    def vanish(profile, method, *args, **kwargs):
        seen.append((profile, method))
        if method == "get_job":
            original("worker", "remove_job", job["id"])
        return original(profile, method, *args, **kwargs)

    monkeypatch.setattr(helpers, "_call_cron_for_profile", vanish)
    monkeypatch.setattr(helpers, "_find_cron_job_profile", lambda _id: pytest.fail("strict lookup scanned profiles"))
    response = client.put(f"/api/cron/jobs/{job['id']}", params=strict("worker"), json={"updates": {"prompt": "new"}})
    assert response.status_code == 404
    assert seen and all(profile == "worker" for profile, _method in seen)
    assert not any(method == "update_job" for _profile, method in seen)


def test_profile_removed_during_history_read_never_falls_back(homes, client, monkeypatch):
    job = create("worker", "history race")
    original = helpers._cron_profile_home
    resolutions = []

    def disappear(profile):
        resolutions.append(profile)
        if len(resolutions) > 2:
            raise routes.HTTPException(status_code=404, detail="Profile removed")
        return original(profile)

    monkeypatch.setattr(helpers, "_cron_profile_home", disappear)
    monkeypatch.setattr(routes, "_open_session_db_for_profile", lambda *_a, **_kw: pytest.fail("read after lost owner"))
    response = client.get(f"/api/cron/jobs/{job['id']}/runs", params=strict("worker"))
    assert response.status_code == 404
    assert all(profile == "worker" for profile in resolutions)


@pytest.mark.parametrize("outcome", ["claimed", "removed", "paused"])
def test_trigger_keeps_existing_claim_and_paused_semantics(homes, client, monkeypatch, outcome):
    job = create("worker", "synthetic fire")
    if outcome == "paused":
        helpers._call_cron_for_profile("worker", "pause_job", job["id"])
    captured = []

    def fire(profile, job_id, *, force=False):
        captured.append((profile, job_id, force))
        if outcome == "removed":
            helpers._call_cron_for_profile(profile, "remove_job", job_id)
        return outcome != "claimed"

    monkeypatch.setattr(helpers, "_fire_cron_job_for_profile", fire)
    response = client.post(f"/api/cron/jobs/{job['id']}/trigger", params=strict("worker"), json={})
    assert captured == [("worker", job["id"], outcome == "paused")]
    assert response.status_code == (409 if outcome == "claimed" else 200)
    if response.status_code == 200:
        assert response.json()["profile"] == "worker" and "strict_profile" not in response.json()
        if outcome == "removed":
            assert response.json()["state"] == "completed"


def test_pause_resume_and_delete_use_the_same_bound_profile(homes, client, monkeypatch):
    job = create("worker", "pause in place")
    path = f"/api/cron/jobs/{job['id']}"
    monkeypatch.setattr(helpers, "_find_cron_job_profile", lambda _id: pytest.fail("bound pause scanned profiles"))
    assert client.post(path + "/pause", params=strict("default")).status_code == 404
    paused = client.post(path + "/pause", params=strict("worker"))
    assert paused.status_code == 200 and paused.json()["profile"] == "worker"
    assert "strict_profile" not in paused.json()
    assert client.post(path + "/resume", params=strict("worker")).status_code == 200
    removed = client.delete(path, params=strict("worker"))
    assert removed.status_code == 200 and removed.json()["profile"] == "worker"
    assert client.get(path, params=strict("worker")).status_code == 404


def test_strict_rejects_noncanonical_id_and_invalid_schedule_without_mutation(homes, client):
    job = create("worker", "full instructions retained")
    path = f"/api/cron/jobs/{job['id']}"
    invalid = client.put(path, params=strict("worker"), json={"updates": {"schedule": "invalid schedule"}})
    assert invalid.status_code == 400
    assert client.get(path, params=strict("worker")).json()["prompt"] == "full instructions retained"
    assert client.get("/api/cron/jobs/unsafe.id/runs", params=strict("worker")).status_code == 400
