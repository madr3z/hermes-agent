"""Pinned Gmail MCP account preset and explicit, profile-scoped install command.

Run ``python -m tools.connectors.google_gmail --help``. This command configures
an external runtime. It does not install software or start an OAuth flow.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
from uuid import UUID, uuid4
from urllib.parse import parse_qs, urlencode, urlparse

from hermes_constants import get_hermes_home
from tools.connectors.account_instances import account_instance_params, account_secret_slots

PROVIDER_VERSION = "2.1.0"
PROVIDER_COMMIT = "789730452b9c5452b2c8d348cf005d196c12ba4e"
PROVIDER_COMMAND = "/opt/hermes-connectors/workspace-mcp-2.1.0/.venv/bin/workspace-mcp"
PROVIDER_ARGS = ["--single-user", "--permissions", "gmail:readonly", "--transport", "stdio"]


def gmail_account_plan(name: str, email: str, callback_port: int, *,
                       profile_home: Path | None = None, controller_origin: str | None = None) -> dict:
    """Build one account's config without reading credentials or writing state."""
    email = email.strip().lower()
    if not re.fullmatch(r"[^\s/@]+@[^\s/@]+\.[^\s/@]+", email):
        raise ValueError("Enter the Google account's full email address.")
    if isinstance(callback_port, bool) or not 1024 <= callback_port <= 65535:
        raise ValueError("Use a callback port between 1024 and 65535.")
    home = profile_home if profile_home is not None else get_hermes_home()
    if not home.is_absolute():
        raise ValueError("The profile home must be an absolute path.")
    namespace = str(uuid4())
    refs, _ = account_secret_slots(namespace, {"CLIENT_ID": "pending", "CLIENT_SECRET": "pending"})
    slots = {key: ref[2:-1] for key, ref in refs.items()}
    directory = home / "connectors" / "google-gmail" / namespace
    config = {
        "command": PROVIDER_COMMAND,
        "args": list(PROVIDER_ARGS),
        "env": {
            "GOOGLE_OAUTH_CLIENT_ID": "${" + slots["CLIENT_ID"] + "}",
            "GOOGLE_OAUTH_CLIENT_SECRET": "${" + slots["CLIENT_SECRET"] + "}",
            "WORKSPACE_MCP_CREDENTIALS_DIR": str(directory),
            "WORKSPACE_MCP_PORT": str(callback_port),
            "WORKSPACE_MCP_BASE_URI": "http://localhost",
            "GOOGLE_OAUTH_REDIRECT_URI": (phone_callback_uri(controller_origin) if controller_origin
                                           else f"http://localhost:{callback_port}/oauth2callback"),
            "USER_GOOGLE_EMAIL": email,
            "MCP_ENABLE_OAUTH21": "false",
            "WORKSPACE_MCP_STATELESS_MODE": "false",
        },
    }
    params = account_instance_params("google-gmail", name, config, account_instance_id=namespace,
                                     requested_identity=email)
    return {**params, "email": email, "secret_slots": slots}


def native_callback_redirect(query: str) -> str:
    """Fixed private-controller HTTPS-to-native relay. No exchange or state mutation.

    The authenticated owning-bot callback receiver must still verify state,
    issuer and PKCE. This helper never selects an account from query parameters.
    """
    if len(query) > 16384:
        raise ValueError("The callback is too large.")
    values = parse_qs(query, keep_blank_values=True)
    allowed = {"code", "state", "error", "iss"}
    if any(len(items) != 1 for items in values.values()):
        raise ValueError("The callback contains duplicate parameters.")
    selected = {key: values[key][0] for key in allowed if key in values}
    if not selected.get("state") or bool(selected.get("code")) == bool(selected.get("error")):
        raise ValueError("The callback requires state and exactly one code or error.")
    return "com.hermes.iphone:/oauth/callback?" + urlencode(selected)


def phone_callback_uri(controller_url: str) -> str:
    """Build the exact Web OAuth redirect to register; do not enable a route."""
    url = urlparse(controller_url)
    host = url.hostname or ""
    import ipaddress

    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("Google Web OAuth requires a DNS host, not a private IP.")
    if (url.scheme != "https" or "." not in host or host.endswith((".local", ".internal"))
            or url.username or url.password or url.query or url.fragment or url.path not in ("", "/")
            or url.port not in (None, 443)):
        raise ValueError("Use the existing private controller's HTTPS DNS origin on port 443.")
    return f"https://{host}/api/connector-callbacks/google"


def install_gmail_account(plan: dict) -> None:
    """Use the existing config writer. Reject duplicate names and callback ports."""
    from hermes_cli.config_write_lock import CONFIG_MUTATION_LOCK
    from hermes_cli.mcp_config import _get_mcp_servers, _save_mcp_server

    with CONFIG_MUTATION_LOCK:
        servers = _get_mcp_servers()
        if plan["name"] in servers:
            raise ValueError("This account name already exists. Choose another name.")
        port = plan["config"]["env"]["WORKSPACE_MCP_PORT"]
        if any(str((server.get("env") or {}).get("WORKSPACE_MCP_PORT", "")) == port
               for server in servers.values()):
            raise ValueError("This callback port is already used. Choose another port.")
        if not _save_mcp_server(plan["name"], plan["config"]):
            raise ValueError("The existing MCP config validator rejected this account.")


def remove_gmail_credentials(profile_home: Path, name: str, config: dict) -> None:
    """Remove one account's local grants after its process and attempts stop.

    This does not revoke the Google-side consent. The caller also removes only
    this instance's config and secret slots through the existing account APIs.
    """
    metadata = config.get("account_instance") or {}
    instance = UUID(metadata["id"])
    owned = profile_home.resolve() / "connectors" / "google-gmail" / str(instance)
    configured = Path((config.get("env") or {}).get("WORKSPACE_MCP_CREDENTIALS_DIR", ""))
    if metadata.get("provider") != "google-gmail" or name != "account-" + instance.hex or configured.resolve() != owned:
        raise ValueError("The Google credential directory does not belong to this account.")
    if owned.exists():
        shutil.rmtree(owned)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--callback-port", required=True, type=int)
    parser.add_argument("--controller-origin", help="Private HTTPS origin with an approved Google Web OAuth redirect.")
    parser.add_argument("--apply", action="store_true", help="Save through the existing MCP config writer.")
    args = parser.parse_args()
    plan = gmail_account_plan(args.name, args.email, args.callback_port, controller_origin=args.controller_origin)
    if args.apply:
        install_gmail_account(plan)
    print(json.dumps(plan, indent=2))


if __name__ == "__main__":
    main()
