"""Local TLS wire fixture: no model, credentials, agent engine or production state."""
import base64
import hashlib
import json
import os
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
        if parsed.path.endswith("/api/ws"):
            if parse_qs(parsed.query).get("token") != ["fixture+token &?"]:
                self.json_reply(401, {"error": "unauthorized"})
                return
            accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            self.frames()
        elif self.headers.get("Authorization") == "Bearer fixture+token &?":
            self.json_reply(200, {"ok": True, "path": parsed.path, "profile": parse_qs(parsed.query).get("profile", [None])[0]})
        else:
            self.json_reply(401, {"error": "unauthorized"})

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
            handlers = {
                "fixture.shared_question": self.shared_question,
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
            if method == "prompt.submit":
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
        return {"status": "streaming", "user_row_id": 2}


with tempfile.TemporaryDirectory(prefix="hermes-phone-wire-") as directory:
    cert, key = os.path.join(directory, "cert.pem"), os.path.join(directory, "key.pem")
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", key, "-out", cert], check=True, timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.clients = []
    server.clients_lock = threading.Lock()
    server.question_answer = None
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    with open(cert, encoding="utf-8") as source:
        der = ssl.PEM_cert_to_DER_cert(source.read())
    print(json.dumps({"port": server.server_port, "certificate": base64.b64encode(der).decode()}), flush=True)
    server.serve_forever()
