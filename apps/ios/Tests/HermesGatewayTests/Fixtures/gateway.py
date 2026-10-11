"""Local TLS wire fixture: no model, credentials, agent engine or production state."""
import base64
import hashlib
import json
import os
import secrets
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def json_reply(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path.endswith(("/api/display/ws", "/api/terminal/ws")):
            self.remote_stream(parsed)
        elif parsed.path.endswith("/api/fixture/remote_events"):
            self.json_reply(200, {"events": self.server.remote_events})
        elif parsed.path.endswith("/api/ws"):
            if not self.ws_authorized(parsed):
                self.json_reply(401, {"error": "unauthorized"})
                return
            accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            self.frames()
        elif parsed.path == "/api/fixture/tickets" and self.cookie_authorized():
            self.json_reply(200, {"minted": self.server.ticket_count})
        elif self.headers.get("Authorization") == "Bearer fixture+token &?" or self.cookie_authorized():
            self.json_reply(200, {"ok": True, "path": parsed.path, "profile": parse_qs(parsed.query).get("profile", [None])[0]})
        else:
            self.json_reply(401, {"error": "unauthorized"})

    def cookie_authorized(self):
        return "__Host-hermes_session_at=fixture-session" in self.headers.get("Cookie", "")

    def ws_authorized(self, parsed):
        query = parse_qs(parsed.query)
        if "token" in query:
            return query["token"] == ["fixture+token &?"]
        ticket = query.get("ticket", [""])[0]
        with self.server.clients_lock:
            if ticket not in self.server.tickets:
                return False
            self.server.tickets.remove(ticket)
        return True

    def do_POST(self):
        parsed = urlparse(self.path)
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        if parsed.path == "/auth/password-login" and data == {"provider": "basic", "username": "fixture-user", "password": "fixture-password", "next": ""}:
            body = json.dumps({"ok": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "__Host-hermes_session_at=fixture-session; Path=/; Max-Age=3600; Secure; HttpOnly")
            self.end_headers()
            self.wfile.write(body)
        elif parsed.path == "/api/auth/ws-ticket" and self.cookie_authorized():
            ticket = secrets.token_urlsafe(24)
            with self.server.clients_lock:
                self.server.tickets.add(ticket)
                self.server.ticket_count += 1
            self.json_reply(200, {"ticket": ticket, "ttl_seconds": 30})
        else:
            self.json_reply(401, {"error": "unauthorized"})

    def remote_stream(self, parsed):
        # Match the production query-token seam, deliberately ignoring Bearer.
        query = parse_qs(parsed.query)
        display = parsed.path.endswith("/api/display/ws")
        if not self.ws_authorized(parsed) or (display and query.get("display_ticket") != ["guest+ticket &?"]):
            self.json_reply(403, {"error": "unauthorized"})
            return
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.remote_frame(2, b"RFB 003.008\n" if display else b"\x1b[32mguest shell\x1b[0m")
        while True:
            frame = self.read_frame()
            if frame is None:
                return
            opcode, data = frame
            if opcode == 8:
                code = struct.unpack("!H", data[:2])[0] if len(data) >= 2 else 1005
                self.server.remote_events.append({"display": display, "close": code})
                self.remote_frame(8, data)
                return
            self.remote_frame(2, data)

    def remote_frame(self, opcode, data):
        prefix = bytes([0x80 | opcode, len(data)]) if len(data) < 126 else bytes([0x80 | opcode, 126]) + struct.pack("!H", len(data))
        self.wfile.write(prefix + data)
        self.wfile.flush()

    def read_frame(self):
        header = self.rfile.read(2)
        if len(header) < 2:
            return None
        size = header[1] & 127
        if size == 126:
            size = struct.unpack("!H", self.rfile.read(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if header[1] & 128 else None
        data = self.rfile.read(size)
        if mask:
            data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
        return header[0] & 15, data

    def send(self, value):
        data = json.dumps(value).encode()
        prefix = bytes([0x81, len(data)]) if len(data) < 126 else bytes([0x81, 126]) + struct.pack("!H", len(data))
        with self.send_lock:
            self.wfile.write(prefix + data)
            self.wfile.flush()

    def frames(self):
        self.send_lock = threading.Lock()
        with self.server.clients_lock:
            self.server.clients.append(self)
        slow_until = 0.0
        self.send({"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {"version": "fixture"}}})
        while True:
            header = self.rfile.read(2)
            if len(header) < 2 or header[0] & 15 == 8:
                return
            size = header[1] & 127
            if size == 126:
                size = struct.unpack("!H", self.rfile.read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.rfile.read(8))[0]
            mask = self.rfile.read(4) if header[1] & 128 else None
            data = self.rfile.read(size)
            if mask:
                data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            if header[0] & 15 != 1:
                # Production gateway consumes receive_text, so binary client frames must fail this test.
                return
            request = json.loads(data)
            if request.get("id") == "shared-question" and "method" not in request:
                with self.server.clients_lock:
                    if self.server.question_answer is None:
                        self.server.question_answer = request.get("result", request.get("error"))
                continue
            method, params = request["method"], request["params"]
            if method == "prompt.submit" and params.get("text") == "legacy immediate" and "client_turn_id" in params:
                self.send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": 4000, "message": "invalid params for prompt.submit: client_turn_id: Extra inputs are not permitted"}})
                continue
            handlers = {
                "fixture.shared_question": self.shared_question,
                "fixture.finish_queued": self.finish_queued,
                "fixture.prompt_count": lambda _: {"accepted": self.server.prompt_count},
                "fixture.question_result": lambda _: {"answer": self.server.question_answer},
                "profiles.list": lambda _: {"profiles": [{"name": "writer", "display_name": "Writer"}]},
                "session.list": self.session_list,
                "session.resume": self.session_resume,
                "prompt.submit": self.prompt_submit,
                "gateway.ping": lambda _: {"ok": True},
                "ping": lambda _: {"pong": True},
            }
            if method == "fixture.slow":
                slow_until = time.monotonic() + 0.5
                reply = {"jsonrpc": "2.0", "id": request["id"], "result": {"ok": True}}
                threading.Timer(0.5, self.send, args=(reply,)).start()
                continue
            handler = handlers.get(method)
            if handler is None:
                self.send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Unsupported fixture RPC"}})
                continue
            if method == "ping":
                # Match production: regular ping sits behind a slow dispatcher method.
                time.sleep(max(0, slow_until - time.monotonic()))
            result = handler(params)
            self.send({"jsonrpc": "2.0", "id": request["id"], "result": result})
            if method == "prompt.submit" and result["status"] != "queued":
                for seq, kind, payload in [(1, "message.start", {}), (2, "message.delta", {"text": "Real wire "}), (3, "message.delta", {"text": "stream"}), (4, "message.complete", {"text": "Real wire stream"})]:
                    self.send({"jsonrpc": "2.0", "method": "event", "params": {"type": kind, "session_id": "runtime", "seq": seq, "payload": payload}})


    def shared_question(self, _):
        frame = {"jsonrpc": "2.0", "id": "shared-question", "method": "approval", "params": {"session_id": "runtime", "command": "fixture action", "choices": ["once", "deny"]}}
        with self.server.clients_lock:
            peers = list(self.server.clients)
        for peer in peers:
            peer.send(frame)
        return {"started": True}

    def session_list(self, params):
        assert params["profile"] == "writer" and params["title"] == "Bot Chat"
        return {"sessions": [{"id": "root", "resolved_id": "tip", "title": "Bot Chat"}]}

    def session_resume(self, params):
        assert params["session_id"] == "tip" and params["profile"] == "writer"
        assert params["close_on_disconnect"] is False
        return {"session_id": "runtime", "stored_session_id": "tip", "messages": [{"role": "user", "text": "Existing canonical history", "row_id": 1}]}

    def prompt_submit(self, params):
        assert params["session_id"] == "runtime" and params["profile"] == "writer"
        self.server.prompt_count += 1
        token = params.get("client_turn_id")
        if params["text"].startswith("queued "):
            assert params["queued"] is True and params["surface"] == "voice-live" and token
            self.server.queued_turns.append(token)
            return {"status": "queued", "client_turn_id": token}
        return {"status": "streaming", "user_row_id": 2, **({"client_turn_id": token} if token else {})}

    def finish_queued(self, _):
        first, second = self.server.queued_turns
        completions = [(first, "late A"), ("unrelated", "typed task"), (None, "uncorrelated result"), (second, "B result"), (second, "duplicate B")]
        for token, text in completions:
            payload = {"status": "complete", "text": text, "persisted_turn": {"user_row_id": 100}}
            if token:
                payload["client_turn_id"] = token
            self.send({"jsonrpc": "2.0", "method": "event", "params": {"type": "message.complete", "session_id": "runtime", "payload": payload}})
        return {"ok": True}


with tempfile.TemporaryDirectory(prefix="hermes-phone-wire-") as directory:
    cert, key = os.path.join(directory, "cert.pem"), os.path.join(directory, "key.pem")
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", key, "-out", cert], check=True, timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.clients = []
    server.clients_lock = threading.Lock()
    server.question_answer = None
    server.prompt_count = 0
    server.queued_turns = []
    server.remote_events = []
    server.tickets = set()
    server.ticket_count = 0
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    with open(cert, encoding="utf-8") as source:
        der = ssl.PEM_cert_to_DER_cert(source.read())
    print(json.dumps({"port": server.server_port, "certificate": base64.b64encode(der).decode()}), flush=True)
    server.serve_forever()
