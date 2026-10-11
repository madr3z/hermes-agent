"""Account identity for existing named MCP instances, independent of labels.

These helpers do not own OAuth, credential persistence, or transport lifecycle.
Call existing operations with the returned immutable server name.
"""

from copy import deepcopy
from pathlib import Path
import re
from uuid import UUID, uuid4, uuid5, NAMESPACE_URL


def account_instance_params(provider: str, label: str, config: dict, *,
                            account_instance_id: str | None = None,
                            requested_identity: str = "") -> dict:
    """Create one MCP add request. Reuse its ID for the same partial setup only."""
    label, provider = label.strip(), provider.strip()
    if not label or len(label) > 120 or any(ord(char) < 32 for char in label):
        raise ValueError("Enter an account label of 1 to 120 printable characters.")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,95}", provider):
        raise ValueError("Use a provider identifier with letters, digits, dots, underscores or hyphens.")
    instance_id = UUID(account_instance_id) if account_instance_id else uuid4()
    copied = deepcopy(config)
    copied["account_instance"] = {
        "id": str(instance_id), "provider": provider, "label": label,
        "requested_identity": requested_identity.strip(),
    }
    return {"name": f"account-{instance_id.hex}", "config": copied}


def account_instance_summary(name: str, config: dict, profile_home: Path) -> dict:
    """Display metadata only. Requested identity never becomes verified identity.

    Legacy server names retain their existing credential namespace. Their IDs
    are stable inside the owning profile; no token migration is required.
    """
    metadata = config.get("account_instance") or {}
    if metadata:
        instance_id = str(UUID(metadata["id"]))
    else:
        instance_id = str(uuid5(NAMESPACE_URL, f"{profile_home.resolve()}#mcp/{name}"))
    return {
        "account_instance_id": instance_id,
        "server_name": name,
        "provider": metadata.get("provider", "custom-mcp"),
        "label": metadata.get("label", name),
        "requested_identity": metadata.get("requested_identity", ""),
        "verified_identity": None,
    }


def resolve_account_instance(servers: dict, instance_id: str, profile_home: Path) -> str:
    """Resolve an exact account inside the selected profile. Never pick a default."""
    wanted = str(UUID(instance_id))
    matches = [name for name, config in servers.items()
               if account_instance_summary(name, config, profile_home)["account_instance_id"] == wanted]
    if len(matches) != 1:
        raise ValueError("The selected account is missing or ambiguous. Refresh the account list.")
    return matches[0]


def account_secret_slots(instance_id: str, environment: dict[str, str]) -> tuple[dict, dict]:
    """Reuse UUID env slots for transient stdio credentials. Return refs and values."""
    prefix = f"MCP_ACCOUNT_{UUID(instance_id).hex.upper()}_"
    refs, secrets = {}, {}
    for key, value in environment.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]{0,95}", key):
            raise ValueError("Use an uppercase environment key.")
        if not value or len(value.encode()) > 4096 or any(char in value for char in "\n\r\0"):
            raise ValueError("Use a non-empty single-line credential of at most 4 KiB.")
        slot = prefix + key
        refs[key] = "${" + slot + "}"
        secrets[slot] = value
    return refs, secrets
