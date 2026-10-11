"""Chat-scoped login cards over the existing authenticated gateway transport."""
from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method


def _login_handoff_owner(rid, params):
    _, session = _current_session_steer_authority(params.get("session_id", ""))
    if session is None or session.get("_finalized"):
        return None, _err(rid, 4001, "This transport does not own the chat")
    if _session_uses_compute_host(session):
        return None, _err(rid, 5033, "Sign in through the bot's owning gateway")
    # A client-supplied profile is a routing assertion, never an authority override.
    if params.get("profile"):
        from hermes_constants import hermes_home_key
        home = _profile_home(params["profile"])
        if hermes_home_key(home or _hermes_home) != hermes_home_key(session.get("profile_home") or _hermes_home):
            return None, _err(rid, 4001, "Login profile does not own this chat")
    return session, None


def _login_handoff_rpc(rid, params, action):
    from pathlib import Path
    from tools.connectors import login_handoff as login
    session, error = _login_handoff_owner(rid, params)
    if error:
        return error
    with _session_profile_runtime_scope(session):
        from hermes_constants import get_hermes_home
        home = Path(get_hermes_home())
        with _session_db(session) as db:
            lineage = db.get_compression_lineage(session["session_key"])
        chat = lineage[0] if lineage else session["session_key"]
        session["_login_handoff_chat"] = chat
        try:
            if action == "list":
                config = _load_cfg()
                required = (config.get("model") or {}).get("provider") == "openai-codex"
                if params.get("account_name"):
                    login.create_mcp(home, chat, params["account_name"])
                return _ok(rid, {"requests": login.list_requests(home, chat, required=required)})
            request_id = params["request_id"]
            if action == "start":
                record = login.start(home, chat, request_id, client_redirect_uri=params.get("client_redirect_uri"))
            elif action == "cancel":
                record = login.cancel(home, chat, request_id, attempt_id=params.get("attempt_id"))
            elif action == "callback":
                record = login.callback(home, chat, request_id, {k: params.get(k) for k in ("code", "state", "error", "iss")})
            else:
                record = login.continuation(home, chat, request_id)
                if record["continued"]:
                    return _ok(rid, {"request": login.public(record)})
                claimed, receipt = login.claim_continuation(home, chat, request_id)
                if not claimed:
                    return _ok(rid, {"request": receipt})
                # client_turn_id is correlation only. The durable claim prevents a second admission.
                submitted = _methods["prompt.submit"](rid, {
                    "session_id": params["session_id"], "queued": True,
                    "client_turn_id": "login-handoff-" + request_id,
                    "text": "Authorization was saved on this bot for " + record["name"] + ". Continue the task that required it. Use the existing tool surface; if new tools require a new session, explain that first."
                })
                if "error" in submitted:
                    return submitted
                record = login.mark_continued(home, chat, request_id)
            return _ok(rid, {"request": record})
        except ValueError:
            return _err(rid, 4001, "Login request is unavailable, changed account, or rejected callback. Refresh and try again.")


@method("login.handoff.list")
def _(rid, params):
    return _login_handoff_rpc(rid, params, "list")


@method("login.handoff.start")
def _(rid, params):
    return _login_handoff_rpc(rid, params, "start")


@method("login.handoff.cancel")
def _(rid, params):
    return _login_handoff_rpc(rid, params, "cancel")


@method("login.handoff.callback")
def _(rid, params):
    return _login_handoff_rpc(rid, params, "callback")


@method("login.handoff.continue")
def _(rid, params):
    return _login_handoff_rpc(rid, params, "continue")


def register(server):
    bind_module(globals(), server, skip=("_",))
