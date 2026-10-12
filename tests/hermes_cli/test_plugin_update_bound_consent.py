"""A catalog grant applies only to the exact installed/target revisions and access delta."""
from copy import deepcopy

import pytest

from hermes_cli import plugins_cmd as pc, plugins_cmd_catalog as cat
from tests.hermes_cli.test_plugins_cmd_catalog import world, _commit, _head
from tests.pm._fixtures import client, isolated_python


@pytest.fixture
def widened(request):
    state = request.getfixturevalue("world")
    target, _, _ = cat.install_catalog_entry(cat.get_live_catalog_entry("cat-plugin"), force=False)
    (state["repo"] / "plugin.yaml").write_text(
        "name: cat-plugin\nversion: 3.0.0\nprovides_tools: [shell_out]\n")
    state["state"]["pin"] = _commit(state["repo"], "add reviewed tool")
    return state, target


def test_bound_update_requires_explicit_exact_review_on_rpc_and_dashboard(widened):
    from tui_gateway import server

    state, target = widened
    handler = server._methods["plugins.manage"]
    before = _head(target)
    refused = handler(1, {"action": "update", "name": "cat-plugin"})["result"]
    assert refused["consent_required"] is True and _head(target) == before
    review = refused["update_review"]
    assert review == {"installed_name": "cat-plugin", "catalog_name": "cat-plugin", "installed_sha": before,
                      "target_sha": state["state"]["pin"], "delta": {"tools": ["shell_out"]}}
    assert "error" in handler(2, {"action": "update", "name": "cat-plugin", "accept_capabilities": True})
    assert pc.dashboard_update_user_plugin("cat-plugin", accept_capabilities=True)["ok"] is False
    assert _head(target) == before
    applied = handler(3, {"action": "update", "name": "cat-plugin", "accept_capabilities": True,
                          "reviewed_update": review})
    assert applied["result"]["ok"] is True, applied
    assert _head(target) == review["target_sha"]
    assert pc.dashboard_update_user_plugin("cat-plugin", accept_capabilities=True,
                                           reviewed_update=review)["ok"] is False


@pytest.mark.parametrize("change", ["catalog", "installed", "delta", "publication_tree"])
def test_stale_or_changed_review_never_publishes(widened, monkeypatch, change):
    state, target = widened
    review = deepcopy(pc.dashboard_update_user_plugin("cat-plugin")["update_review"])
    before = _head(target)
    if change == "catalog":
        (state["repo"] / "plugin.yaml").write_text(
            "name: cat-plugin\nversion: 4.0.0\nprovides_tools: [shell_out, another_tool]\n")
        state["state"]["pin"] = _commit(state["repo"], "catalog moved after review")
    elif change == "installed":
        metadata = pc._read_install_metadata()
        metadata["cat-plugin"]["catalog"]["sha"] = state["sha2"]
        pc._write_install_metadata(metadata)
    elif change == "delta":
        review["delta"]["tools"] = []
    else:
        clone = pc._clone_plugin_repo
        calls = 0

        def changed_publication_tree(*args, **kwargs):
            nonlocal calls
            revision = clone(*args, **kwargs)
            calls += 1
            if calls == 2:
                (args[0] / "plugin.yaml").write_text(
                    "name: cat-plugin\nversion: 3.0.0\nprovides_tools: [shell_out, unreviewed_tool]\n")
            return revision

        monkeypatch.setattr(pc, "_clone_plugin_repo", changed_publication_tree)
    metadata = pc._read_install_metadata()
    result = pc.dashboard_update_user_plugin("cat-plugin", accept_capabilities=True, reviewed_update=review)
    assert result["ok"] is False, result
    assert "review" in result["error"].lower()
    assert _head(target) == before
    assert pc._read_install_metadata() == metadata
