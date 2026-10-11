"""Native OAuth uses one app-owned callback without weakening relay ownership."""

from types import SimpleNamespace

import pytest

from tools.connectors.mcp_oauth import (
    _validate_client_redirect_uri,
    choose_callback_receiver,
)


def test_native_callback_is_exact_and_does_not_bind_a_gateway_listener():
    uri = "com.hermes.iphone:/oauth/callback"
    assert _validate_client_redirect_uri(uri) == uri
    flow = SimpleNamespace(redirect_uri="")
    assert choose_callback_receiver(flow, {}, uri) is None
    assert flow.redirect_uri == uri
    for rejected in (
        "com.other.app:/oauth/callback",
        "com.hermes.iphone://oauth/callback",
        uri + "?code=unexpected",
        uri + "#fragment",
        uri + "/extra",
        "COM.HERMES.IPHONE:/oauth/callback",
    ):
        with pytest.raises(ValueError):
            _validate_client_redirect_uri(rejected)


def test_native_callback_cannot_replace_a_providers_registered_loopback():
    flow = SimpleNamespace(redirect_uri="")
    cfg = {"oauth": {"client_id": "provider-client", "redirect_port": 27890}}
    with pytest.raises(ValueError, match="registered loopback"):
        choose_callback_receiver(flow, cfg, "com.hermes.iphone:/oauth/callback")
    assert flow.redirect_uri == ""
    assert choose_callback_receiver(flow, cfg) is None
    assert flow.redirect_uri == "http://127.0.0.1:27890/callback"
