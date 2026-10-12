"""Existing read-only mobile skill/memory routes keep explicit profiles isolated."""
import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from hermes_cli import profiles
from hermes_constants import get_hermes_home


@pytest.fixture
def homes(tmp_path, monkeypatch):
    launch = get_hermes_home()
    worker = launch / "profiles" / "worker"
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setattr(profiles, "_get_default_hermes_home", lambda: launch)
    monkeypatch.setattr(profiles, "_get_profiles_root", lambda: launch / "profiles")
    for home, label in ((launch, "Launch"), (worker, "Worker")):
        home.mkdir(parents=True, exist_ok=True)
        (home / "config.yaml").write_text("{}\n")
        skill = home / "skills" / "shared" / "SKILL.md"
        skill.parent.mkdir(parents=True, exist_ok=True)
        skill.write_text(f"---\nname: shared\ndescription: {label} synthetic skill.\n---\n{label} instructions.\n")
        memories = home / "memories"
        memories.mkdir(exist_ok=True)
        (memories / "MEMORY.md").write_text(f"{label} synthetic memory.\n")
        (memories / "USER.md").write_text(f"{label} synthetic user note.\n")
    return launch, worker


@pytest.fixture
def client(homes):
    from hermes_cli.web_server import app, _SESSION_HEADER_NAME, _SESSION_TOKEN
    client = TestClient(app)
    client.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    return client


def test_skill_list_content_and_toggle_use_only_requested_profile(client, homes):
    launch, worker = homes
    before = (launch / "config.yaml").read_bytes()
    environment = dict(os.environ)
    response = client.get("/api/skills", params={"profile": "worker"})
    assert response.status_code == 200, response.text
    skill = next(row for row in response.json() if row["name"] == "shared")
    assert skill["description"] == "Worker synthetic skill."
    assert skill["enabled"] is True
    response = client.get("/api/skills/content", params={"profile": "worker", "name": "shared"})
    assert response.status_code == 200, response.text
    assert "Worker instructions." in response.json()["content"]
    assert "Launch instructions." not in response.json()["content"]
    response = client.put("/api/skills/toggle", params={"profile": "worker"}, json={"name": "shared", "enabled": False})
    assert response.status_code == 200, response.text
    rows = client.get("/api/skills", params={"profile": "worker"}).json()
    assert next(row for row in rows if row["name"] == "shared")["enabled"] is False
    rows = client.get("/api/skills", params={"profile": "default"}).json()
    assert next(row for row in rows if row["name"] == "shared")["enabled"] is True
    assert (launch / "config.yaml").read_bytes() == before
    assert dict(os.environ) == environment
    assert (worker / "config.yaml").read_bytes() != before


def test_memory_list_detail_and_stale_ids_stay_with_requested_profile(client, homes):
    launch, worker = homes
    frozen = {str(path): path.read_bytes() for home in homes for path in (home / "memories").iterdir()}
    environment = dict(os.environ)
    response = client.get("/api/learning/graph", params={"profile": "worker"})
    assert response.status_code == 200, response.text
    cards = [row for row in response.json()["nodes"] if row["kind"] == "memory"]
    assert {row["label"] for row in cards} == {"Worker synthetic memory.", "Worker synthetic user note."}
    for card in cards:
        detail = client.get("/api/learning/node", params={"profile": "worker", "id": card["id"]})
        assert detail.status_code == 200, detail.text
        assert "Worker synthetic" in detail.json()["content"]
        assert client.get("/api/learning/node", params={"profile": "default", "id": card["id"]}).status_code == 404
    for path, content in frozen.items():
        assert Path(path).read_bytes() == content
    assert dict(os.environ) == environment
    memory_card = next(row for row in cards if row["memorySource"] == "memory")
    (worker / "memories/MEMORY.md").write_text("Replacement synthetic memory.\n")
    response = client.get("/api/learning/node", params={"profile": "worker", "id": memory_card["id"]})
    assert response.status_code == 404
    assert "stale" in response.text
    assert (launch / "memories/MEMORY.md").read_bytes() == frozen[str(launch / "memories/MEMORY.md")]


@pytest.mark.parametrize("path,query", [
    ("/api/skills", {}), ("/api/skills/content", {"name": "shared"}),
    ("/api/learning/graph", {}), ("/api/learning/node", {"id": "memory:memory:0:000000000000"}),
])
def test_unknown_profile_reads_never_fall_back(client, path, query):
    response = client.get(path, params={"profile": "missing", **query})
    assert response.status_code == 404


def test_unknown_owner_and_invalid_toggle_do_not_write(client, homes):
    before = {str(home): (home / "config.yaml").read_bytes() for home in homes}
    response = client.put("/api/skills/toggle", params={"profile": "missing"}, json={"name": "shared", "enabled": False})
    assert response.status_code == 404
    response = client.put("/api/skills/toggle", params={"profile": "worker"}, json={"name": "shared", "enabled": {}})
    assert response.status_code == 422
    assert {str(home): (home / "config.yaml").read_bytes() for home in homes} == before
