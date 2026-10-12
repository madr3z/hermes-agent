"""GPT Live transcript persistence, independent of prompt submission."""
from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped


def _voice_live_session(rid, params):
    transport, session = _current_session_steer_authority(params.get('session_id'))
    if transport is None or session is None:
        return None, _err(rid, 4001, "session not found or not owned by this transport")
    if (refusal := _reattach_refusal(rid, params['session_id'], session)) is not None:
        return None, refusal
    return session, None


@method("voice.live.transcript.append")
@_profile_scoped
def _(rid, params):
    from hermes_state_voice import append_voice_fragment
    session, error = _voice_live_session(rid, params)
    if error:
        return error
    with session['history_lock']:
        if _ensure_session_db_row(session) is False:
            return _db_unavailable_error(rid, code=5030)
        with _session_db(session) as db:
            if db is None:
                return _db_unavailable_error(rid, code=5030)
            key = db.resolve_resume_session_id(_submit_row_target_key(session))
            message = append_voice_fragment(db, key, params)
    _emit("voice.live.transcript", params['session_id'], {'message': message})
    return _ok(rid, {'message': message})


@method("voice.live.transcript.list")
@_profile_scoped
def _(rid, params):
    from hermes_state_voice import voice_messages
    session, error = _voice_live_session(rid, params)
    if error:
        return error
    with _session_db(session) as db:
        if db is None:
            return _db_unavailable_error(rid, code=5030)
        messages = voice_messages(db, db.resolve_resume_session_id(session['session_key']))
    return _ok(rid, {'messages': messages})


def _voice_resume_messages(context, display):
    from hermes_state_voice import merge_voice_messages
    if context.omit_messages:
        return []
    messages = _history_to_messages(display, profile_home=context.profile_home, image_urls=context.inline_images)
    return merge_voice_messages(context.db, context.target, messages)



def _voice_live_payload(session, payload):
    """Warm activate/resume and deferred hydration share the cold-resume speech overlay."""
    from hermes_state_voice import merge_voice_messages
    with _session_db(session) as db:
        if db is None or not session.get('session_key'):
            return payload
        key = db.resolve_resume_session_id(session['session_key'])
        if payload.get('messages_omitted'):
            stored = db.get_session(key)
            if stored:
                payload['message_count'] = max(payload['message_count'], stored['message_count'])
        else:
            payload['messages'] = merge_voice_messages(db, key, payload['messages'])
            payload['message_count'] = len(payload['messages'])
    return payload


@method("voice.live.call.bind")
@_profile_scoped
def _(rid, params):
    from tui_gateway.voice_call_control import bind_call
    session, error = _voice_live_session(rid, params)
    if error:
        return error
    transport = current_transport()
    if not _transport_is_live_peer(transport):
        return _err(rid, 4001, "Call controls require a live owning client")
    try:
        bind_call(session, transport, params)
    except ValueError as exc:
        return _err(rid, 4090, str(exc))
    return _ok(rid, {'bound': True})


@method("voice.live.call.unbind")
@_profile_scoped
def _(rid, params):
    from tui_gateway.voice_call_control import unbind_call
    session, error = _voice_live_session(rid, params)
    if error:
        return error
    unbind_call(session, current_transport(), params['call_id'])
    return _ok(rid, {'bound': False})


def register(server):
    bind_module(globals(), server, skip=('_',))
