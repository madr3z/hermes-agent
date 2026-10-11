"""Offline transport fixture using the installed, pinned upstream provider.

Only Google transport boundaries are replaced. OAuth storage, credential lookup,
refresh logic, service decorators, tool registration and MCP transport stay real.
"""

import asyncio
from datetime import datetime, timedelta
from importlib.metadata import version
import json
import os
from pathlib import Path
import socket
import sys
from types import SimpleNamespace

assert version("workspace-mcp") == "2.1.0"


def block_network(*args, **kwargs):
    raise AssertionError("External network is forbidden in the Gmail fixture.")


socket.create_connection = block_network
socket.socket.connect = block_network

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from auth.credential_store import LocalDirectoryCredentialStore
from auth import google_auth


def token_request(self, url, method="GET", body=None, headers=None, **kwargs):
    from urllib.parse import parse_qs

    assert url == "https://oauth2.googleapis.com/token"
    values = parse_qs(body.decode() if isinstance(body, bytes) else body)
    refresh_token = values["refresh_token"][0]
    if refresh_token.startswith("revoked:"):
        return SimpleNamespace(status=400, data=b'{"error":"invalid_grant"}')
    email = refresh_token.removeprefix("refresh:")
    return SimpleNamespace(status=200, data=json.dumps({
        "access_token": f"access:{email}", "expires_in": 3600,
        "token_type": "Bearer", "refresh_token": refresh_token,
    }).encode())


Request.__call__ = token_request


class GmailFixture:
    def __init__(self, credentials):
        self.credentials = credentials
        self._http = SimpleNamespace(credentials=credentials, http=SimpleNamespace(close=lambda: None))

    def users(self):
        return self

    def messages(self):
        return self

    def list(self, **params):
        assert params["userId"] == "me"
        return self

    def execute(self):
        email = self.credentials.token.removeprefix("access:")
        return {"messages": [{"id": f"identity:{email}", "threadId": "fixture-thread"}]}

    def close(self):
        pass


google_auth.build_google_service = lambda service, api_version, credentials: GmailFixture(credentials)


async def missing_account(**kwargs):
    raise google_auth.GoogleAuthenticationError("Fixture: selected account needs authorization.")


real_start_auth_flow = google_auth.start_auth_flow
google_auth.start_auth_flow = missing_account


def callback_proof(email, returned_email):
    import re
    from urllib.parse import parse_qs, urlencode, urlparse
    import requests
    from starlette.testclient import TestClient
    from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware
    from auth.oauth_callback_server import MinimalOAuthServer
    from auth.scopes import get_current_scopes, set_enabled_tools, set_read_only

    set_enabled_tools(["gmail"])
    set_read_only(True)
    google_auth.webbrowser.open = lambda url: False
    redirect = os.environ["GOOGLE_OAUTH_REDIRECT_URI"]
    message = asyncio.run(real_start_auth_flow(email, "Gmail", redirect))
    url = re.search(r"https://accounts\.google\.com/\S+", message)[0]
    params = parse_qs(urlparse(url).query)
    assert params["code_challenge_method"] == ["S256"]
    assert params["redirect_uri"] == [redirect]

    def exchange(self, method, url, **kwargs):
        assert method.upper() == "POST" and url == "https://oauth2.googleapis.com/token"
        values = kwargs["data"]
        assert values["redirect_uri"] == redirect and values["code_verifier"]
        assert values["code"] == "fixture-code"
        response = requests.Response()
        response.status_code = 200
        response.request = requests.Request(method, url, data=values).prepare()
        response.url = url
        response._content = json.dumps({"access_token": "fixture-access", "refresh_token": "fixture-refresh",
                                        "token_type": "Bearer", "expires_in": 3600,
                                        "scope": " ".join(get_current_scopes())}).encode()
        return response

    requests.sessions.Session.request = exchange
    google_auth.get_user_info = lambda credentials: {"email": returned_email, "verified_email": True}
    app = ProxyHeadersMiddleware(MinimalOAuthServer().app, trusted_hosts="127.0.0.1")
    with TestClient(app, base_url="http://127.0.0.1", client=("127.0.0.1", 50000)) as client:
        response = client.get("/oauth2callback?" + urlencode({"state": params["state"][0], "code": "fixture-code"}),
                              headers={"X-Forwarded-Proto": "https"})
    assert response.status_code == 200, response.text
    return {"users": LocalDirectoryCredentialStore().list_users(), "authorization_url": url}


def main():
    store = LocalDirectoryCredentialStore()

    def seed():
        email, state = sys.argv[2:4]
        prefix = "revoked:" if state == "revoked" else "refresh:"
        credentials = Credentials(
            token=f"stale:{email}", refresh_token=f"{prefix}{email}",
            token_uri="https://oauth2.googleapis.com/token", client_id="fixture-client",
            client_secret="fixture-secret", scopes=["https://www.googleapis.com/auth/gmail.readonly"],
            expiry=datetime.utcnow() - timedelta(hours=1),
        )
        assert store.store_credential(email, credentials)
        print(json.dumps({"stored": email}))

    def probe():
        email = sys.argv[2]
        result = google_auth.get_credentials(email, ["https://www.googleapis.com/auth/gmail.readonly"])
        print(json.dumps({"email": email, "token": result.token if result else None,
                          "users": store.list_users()}))

    def serve():
        import main as provider

        sys.argv = ["workspace-mcp", *sys.argv[2:]]
        provider.main()
    actions = {"seed": seed, "probe": probe, "serve": serve,
               "callback-proof": lambda: print(json.dumps(callback_proof(*sys.argv[2:4])))}
    actions[sys.argv[1]]()


if __name__ == "__main__":
    main()
