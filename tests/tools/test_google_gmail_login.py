"""Google phone consent binds the existing attempt to one account and grant."""

from copy import deepcopy
import json
from pathlib import Path
from urllib.parse import urlencode

import pytest

from tools.connectors.google_gmail import gmail_account_plan, remove_gmail_credentials
from tools.connectors.google_gmail_login import GMAIL_SCOPE, begin, cancel, complete, grant_ref


def account(home, email="fixture@gmail.com", port=8711):
    return gmail_account_plan("My mail", email, port, profile_home=home,
                              controller_origin="https://private.example.com")


def consent(plan, attempt):
    def provider(name, arguments):
        assert name == plan["name"]
        assert arguments == {"service_name": "Gmail", "user_google_email": plan["email"]}
        url = "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode({
            "redirect_uri": plan["config"]["env"]["GOOGLE_OAUTH_REDIRECT_URI"],
            "state": "fixture-state-with-enough-entropy", "scope": GMAIL_SCOPE,
            "code_challenge_method": "S256", "code_challenge": "fixture-pkce",
        })
        return json.dumps({"result": "Authorize:\n" + url + "\nReturn to Hermes."})

    return begin(attempt, Path(plan["config"]["env"]["WORKSPACE_MCP_CREDENTIALS_DIR"]).parents[2],
                 plan["name"], plan["config"], provider_call=provider, now=100, expires_at=200)


def save_grant(plan, email=None, token="fixture-access"):
    directory = Path(plan["config"]["env"]["WORKSPACE_MCP_CREDENTIALS_DIR"])
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / ((email or plan["email"]) + ".json")
    path.write_text(json.dumps({"token": token, "refresh_token": "fixture-refresh", "scopes": [GMAIL_SCOPE]}))
    return path


def test_phone_consent_verifies_identity_and_pins_only_selected_grant(tmp_path):
    plan = account(tmp_path)
    sibling = account(tmp_path, "sibling@gmail.com", 8712)
    sibling_path = save_grant(sibling)
    unchanged = sibling_path.read_bytes()
    attempt = {}
    native = consent(plan, attempt)
    assert native["auth_url"].startswith("https://accounts.google.com/")
    assert native["scopes"] == [GMAIL_SCOPE]
    assert grant_ref(tmp_path, plan["name"], plan["config"]) == ""

    def exchange(url, params):
        assert url == "http://127.0.0.1:8711/oauth2callback"
        assert params == {"code": "fixture-code", "state": attempt["google_gmail"]["state"]}
        save_grant(plan)
        return 200

    result = complete(attempt, tmp_path, plan["name"], plan["config"],
                      {"state": attempt["google_gmail"]["state"], "code": "fixture-code"},
                      callback_get=exchange, userinfo=lambda token: {
                          "email": plan["email"], "verified_email": True}, now=150)
    assert result == {"verified_identity": plan["email"], "account_ref": plan["name"],
                      "grant_ref": grant_ref(tmp_path, plan["name"], plan["config"])}
    assert sibling_path.read_bytes() == unchanged
    with pytest.raises(ValueError, match="used"):
        complete(attempt, tmp_path, plan["name"], plan["config"], {}, now=151)


@pytest.mark.parametrize("failure", ["state", "issuer", "expired", "cancelled", "owner", "config"])
def test_callback_rejects_invalid_attempt_before_exchange(tmp_path, failure):
    plan = account(tmp_path)
    attempt = {}
    consent(plan, attempt)
    params = {"state": attempt["google_gmail"]["state"], "code": "fixture-code"}
    name, config, now = plan["name"], deepcopy(plan["config"]), 150
    changed = deepcopy(config)
    changed["env"]["WORKSPACE_MCP_PORT"] = "8712"
    params, cancelled, name, config, now = {
        "state": ({**params, "state": "wrong-state"}, False, name, config, now),
        "issuer": ({**params, "iss": "https://wrong.invalid"}, False, name, config, now),
        "expired": (params, False, name, config, 200),
        "cancelled": (params, True, name, config, now),
        "owner": (params, False, account(tmp_path, "other@gmail.com", 8712)["name"], config, now),
        "config": (params, False, name, changed, now),
    }[failure]
    attempt["cancelled"] = cancelled

    def forbidden(*args):
        pytest.fail("Rejected callback reached the provider.")

    with pytest.raises(ValueError):
        complete(attempt, tmp_path, name, config, params, callback_get=forbidden, now=now)


@pytest.mark.parametrize("failure", ["wrong-account", "unverified", "cancelled-during-exchange"])
def test_rejected_google_grant_restores_prior_account_and_disconnects_only_its_process(tmp_path, failure):
    plan = account(tmp_path)
    old_path = save_grant(plan, token="fixture-old-access")
    prior = old_path.read_bytes()
    attempt = {}
    consent(plan, attempt)
    disconnected = []

    def exchange(url, params):
        save_grant(plan, email="wrong@gmail.com" if failure == "wrong-account" else None)
        if failure == "cancelled-during-exchange":
            attempt["cancelled"] = True
        return 200

    with pytest.raises(ValueError, match="No new local grant"):
        complete(attempt, tmp_path, plan["name"], plan["config"],
                 {"state": attempt["google_gmail"]["state"], "code": "fixture-code"},
                 callback_get=exchange, userinfo=lambda token: {
                     "email": plan["email"], "verified_email": failure != "unverified"},
                 disconnect=disconnected.append, now=150)
    assert disconnected == [plan["name"]]
    assert old_path.read_bytes() == prior
    assert list(old_path.parent.glob("*.json")) == [old_path]


def test_cancel_discards_provider_state_and_preserves_existing_grant(tmp_path):
    plan = account(tmp_path)
    path = save_grant(plan)
    prior = path.read_bytes()
    attempt = {}
    consent(plan, attempt)
    disconnected = []
    cancel(attempt, disconnect=disconnected.append)
    assert disconnected == [plan["name"]]
    assert path.read_bytes() == prior
    with pytest.raises(ValueError, match="cancelled"):
        complete(attempt, tmp_path, plan["name"], plan["config"], {}, now=150)


def test_local_account_removal_deletes_only_the_owned_google_directory(tmp_path):
    accounts = [account(tmp_path, f"fixture-{i}@gmail.com", 8711 + i) for i in range(3)]
    paths = [save_grant(plan) for plan in accounts]
    states = paths[1].parent / "oauth_states.json"
    states.write_text('{"fixture-state": {}}')
    remove_gmail_credentials(tmp_path, accounts[1]["name"], accounts[1]["config"])
    assert not paths[1].parent.exists()
    assert paths[0].exists() and paths[2].exists()
    wrong = deepcopy(accounts[0]["config"])
    wrong["env"]["WORKSPACE_MCP_CREDENTIALS_DIR"] = str(paths[2].parent)
    with pytest.raises(ValueError, match="does not belong"):
        remove_gmail_credentials(tmp_path, accounts[0]["name"], wrong)
    assert paths[0].exists() and paths[2].exists()
