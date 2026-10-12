"""Saved transcript views project private skill scaffolding without changing model history."""
from tests.hermes_cli.test_web_server_sessions_compression import _SessionsCompressionEndpoints


class TestSkillDisplay(_SessionsCompressionEndpoints):
    def test_skill_invocation_is_projected_and_stored_context_is_unchanged(self):
        from agent.skill_commands import _build_skill_message, describe_skill_invocation
        from hermes_state import SessionDB
        body = _build_skill_message(
            {"name": "review", "content": "PRIVATE SKILL INSTRUCTIONS"}, None,
            '[IMPORTANT: The user has invoked the "review" skill. The full skill content is loaded below.]',
            user_instruction="Review this patch")
        with SessionDB() as db:
            db.create_session(session_id="saved", source="cli")
            db.append_message("saved", role="user", content=body)
        response = self.auth_client.get("/api/sessions/saved/messages?profile=default&inline_images=false")
        assert response.status_code == 200
        message = response.json()["messages"][0]
        assert message["display_content"] == describe_skill_invocation(body, separator=" ")
        assert "PRIVATE SKILL INSTRUCTIONS" not in message["display_content"]
        with SessionDB() as db:
            assert db.get_messages("saved")[0]["content"] == body
        assert self.client.get("/api/sessions/saved/messages").status_code == 401

    def test_default_history_never_reads_another_profile_store(self, tmp_path, monkeypatch):
        from hermes_cli import web_server_sessions
        from hermes_constants import get_hermes_home
        from hermes_state import SessionDB
        default = get_hermes_home() / "state.db"
        foreign = tmp_path / "other" / "state.db"
        foreign.parent.mkdir()
        with SessionDB(db_path=default) as db:
            db.create_session("owned", source="cli")
            db.append_message("owned", role="user", content="owned search phrase")
        with SessionDB(db_path=foreign) as db:
            db.create_session("foreign", source="cli")
            db.append_message("foreign", role="user", content="foreign search phrase")
        monkeypatch.setattr(web_server_sessions, "_session_db_path_for_profile", lambda profile: foreign if profile == "other" else default)
        assert self.auth_client.get("/api/sessions/foreign/messages?profile=default").status_code == 404
        listed = self.auth_client.get("/api/sessions?profile=default&min_messages=1").json()
        assert "foreign" not in str(listed) and "owned" in str(listed)
        found = self.auth_client.get("/api/sessions/search?profile=default&q=foreign").json()
        assert "foreign search phrase" not in str(found)
