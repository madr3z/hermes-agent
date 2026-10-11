"""Human-only login cards. Authorization URLs and device codes stay on the UI wire."""
from .base import Params, Payload, Result
from .registry import method


class LoginHandoffParams(Params):
    session_id: str
    profile: str | None = None
    account_name: str | None = None


class LoginHandoffActionParams(LoginHandoffParams):
    request_id: str
    client_redirect_uri: str | None = None
    attempt_id: str | None = None


class LoginHandoffCallbackParams(LoginHandoffActionParams):
    code: str | None = None
    state: str | None = None
    error: str | None = None
    iss: str | None = None


class LoginHandoffRequest(Payload):
    id: str
    provider: str
    name: str
    owner_profile: str
    scopes: list[str]
    status: str
    detail: str
    account_ref: str
    verified_identity: str | None = None
    attempt_id: str | None = None
    continuation_status: str = ""
    user_code: str
    verification_url: str
    auth_url: str
    expires_at: float
    continued: bool


class LoginHandoffListResult(Result):
    requests: list[LoginHandoffRequest]


class LoginHandoffActionResult(Result):
    request: LoginHandoffRequest


method("login.handoff.list", params=LoginHandoffParams, result=LoginHandoffListResult)
for action in ("start", "cancel", "continue"):
    method("login.handoff." + action, params=LoginHandoffActionParams, result=LoginHandoffActionResult)
method("login.handoff.callback", params=LoginHandoffCallbackParams, result=LoginHandoffActionResult)
