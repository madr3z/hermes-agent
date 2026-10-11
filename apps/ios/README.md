# Hermes for iPhone

Native SwiftUI client for an existing authenticated HTTPS Hermes gateway. iOS 17+, iPhone-first. The app is a first-party gateway client under `apps/ios`; it does not add an agent engine, Kubernetes access or model tools to core.

Open `HermesPhone.xcodeproj`, choose `HermesPhone`, and select an iPhone simulator. For a physical phone select your signing team and a unique bundle ID. No signing identity, provisioning profile, TestFlight or App Store release is included.

## Build and checks

```sh
swift test --package-path apps/ios
xcodebuild -project apps/ios/HermesPhone.xcodeproj -scheme HermesPhone \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/ios/HermesPhone.xcodeproj -scheme HermesPhone \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The Swift package contains transport and ownership behavior tests. The local wire integration fixture creates a temporary self-signed TLS certificate and pins exactly that certificate in the **test-only** URLSession delegate. The production client uses normal system TLS trust and rejects non-HTTPS endpoints. The fixture speaks JSON-RPC over a real text WebSocket, but does not execute a Hermes agent or contact a model. Python 3 and `/usr/bin/openssl` are required for this test.

## Connection and ownership

Enter an HTTPS gateway base URL and its access token. Tokens are stored in Keychain as `WhenUnlockedThisDeviceOnly`; only gateway labels/URLs and non-secret provisioning retry settings are stored in preferences. An invalid token is never saved as a working connection. The WebSocket follows the existing `serve` query-token contract; no credential-bearing URL is logged. HTTP uses bearer auth.

- `profiles.list(include_sessions:true)` supplies the roster.
- Opening a bot resolves `session.list(title:"Bot Chat",include_hidden:true,profile)` every time, resumes its `resolved_id`, and uses the returned **runtime** ID for later RPC calls.
- A missing registry row uses `session.create` plus eager `session.title`. A concurrent creator's registry winner is adopted before any prompt is sent. A failed lookup never creates a replacement chat.
- `prompt.submit` streams gateway events; Stop uses `session.interrupt`. Reconnection restores the authoritative transcript, including in-flight output. The app does not close sessions when leaving a screen or backgrounding; bot services and healthy work stay on the VM under existing server lifecycle policy.
- Unsupported server requests are left unanswered so a capable shared Desktop client can respond. The phone never approves them. This initial client does not render desktop-only tools, attachments, approval/clarification dialogs or session editing.

## GPT Live

Native WebRTC audio uses the gateway's existing `POST /api/audio/voice-live/session?profile=…` SDP exchange. The provider key stays on the gateway. An audio track and `oai-events` data channel handle full-duplex speech, provider-side barge-in, mute and close. `session.delegation.created` submits the latest spoken user request to the same bot runtime with bounded spoken context; task output returns through `session.commentary.append` only when its `client_turn_id` matches the UUID generated for that submitted delegation. This correlation survives queued and compute-isolated execution, and completion may arrive before the submit acknowledgement. Superseded, unrelated and duplicate results are ignored. The phone waits for an interrupted voice task to become idle before submitting its replacement.

The gateway must support optional `client_turn_id` on `prompt.submit`, echo it on the accepted result, and carry it through queue/compute dispatch to `message.complete`. An older server that explicitly rejects this field during parameter validation is tried once without it; that rejection happens before dispatch, so it does not create a second model call. No uncertain or accepted submission is retried. Immediate legacy turns can still use their persisted user-row receipt; older queued/isolated turns without either identity remain visible in Bot Chat with an explicit unsupported message.

Persistence requires `voice.live.transcript.list` and `.append` on the backend. Calls fail before microphone acquisition if that contract is missing. Fragments retain stable call/event/utterance IDs, are retried idempotently, and upsert full accumulated display messages by `display_metadata.voice_message_id`. Unsynced fragments use an atomic local outbox protected with iOS complete file protection, retried after canonical resume. A call stops when its sheet closes or the app backgrounds; the bot's delegated task continues on the gateway. Pending-transcript failures remain visible.

Native audio dependency: [stasel/WebRTC](https://github.com/stasel/WebRTC), M154 (`154.0.0`), pinned to Git revision `0c0ad84dac6c1941c16a414dfcfba94691866e4c`. Its binary artifact is checksum-pinned by that package (`a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16`). This is a community distribution of Google WebRTC, not an Apple or OpenAI SDK. Its BSD-3-Clause license is included in the app's resources as `WebRTC-LICENSE.txt`. The package supplies device arm64 and simulator arm64/x86_64 slices.

## Create Bot

The main gateway needs the provisioning plugin:

- `GET /api/plugins/bot-provisioning/v1/capabilities`
- `POST /api/plugins/bot-provisioning/v1/requests`
- `GET /api/plugins/bot-provisioning/v1/requests`

The form consumes backend CPU/memory/disk bounds and defaults. Copy Credentials is off by default and copies server-side allowlisted provider API keys only. The bot name is the exact Linux username: 1–32 ASCII characters, starting with a lowercase letter, followed by lowercase letters, digits, `_` or `-`. Server-advertised reserved usernames are rejected. The user chooses and confirms a VM password of 8–256 UTF-8 bytes without NUL, CR or LF. The confirmation stays on the phone; only the HTTPS POST carries top-level `linux_password`. This VM login is separate from controller authentication.

The request UUID and exact non-secret settings survive an uncertain send. Passwords stay in transient secure form state and never enter preferences or saved retry bodies. Accepted submission or leaving the form clears the password fields. Recovery and retries first GET the saved request ID. A found receipt recovers without a password. Only a 404 permits explicit re-entry of the original password and POST with the same UUID and settings. Other lookup failures block POST; a changed password or body receives the server's generic 409. A controller without the Linux account capability cannot create a new bot from this form. Ready results supply `{id,label,base_url,profile:"default"}`; the phone accepts only the same-origin provisioning proxy path. The main token stays in Keychain and is used to access that proxy; no guest token is returned to the phone.

A missing plugin or unavailable service is shown as unavailable, not as a created VM. The running Infra pilot is not changed by this client implementation.

## Acceptance boundaries

See `VALIDATION.md` for exact build/test evidence. Simulator launch cannot establish physical microphone, Bluetooth/speaker routing, barge-in quality, background recovery on a real mobile network, device signing or TestFlight acceptance. Live gateway/VM provisioning and provider voice calls require the configured private HTTPS proxy and a deliberate live acceptance run.

## VM screen, terminal and power

Open **VM controls** from a bot's chat toolbar. The surrounding roster, chat, voice and VM controls remain native SwiftUI; the two focused remote surfaces use bundled [renderer sources](RemoteRenderers/README.md). Portrait and landscape are supported. Screen is initially view-only. **Take control** uses the guest's existing human/agent lease; **Hand back** relinquishes it. Touch supports pointer movement, dragging, right click and scrolling. Use Keyboard, Ctrl, navigation keys, Fit/1:1, Pan and explicit Paste for remote work. Leaving or backgrounding the view closes its attachment without stopping the guest or terminating its desktop/shell.

The main gateway proxy must support sibling `/api/display/ws` and `/api/terminal/ws` under the registered guest route. Native WSS uses the same main query-token authentication as `/api/ws`; display also sends the independent single-use guest `display_ticket`. These authenticated URLs stay in URLSession and never enter JavaScript, preferences, debug output or navigation. RPC event listeners coexist with chat, bind to the gateway client plus `profile_key`, and compare the human lease's viewer hash. Abnormal transport/RPC failures close with 1011, preserving the lease; intentional departure closes with 1000. A viewer ID is reused only while its original RPC owner remains connected.

Terminal requires `/api/terminal/status` with `available:true` and `protocol:hermes-terminal-v1`. Binary output is raw UTF-8/ANSI; binary input is keyboard bytes, with JSON text resize frames. It attaches to the guest's fixed `default` tmux session as the Hermes user in its workspace. Reconnect restores the same session. A newer attachment owns input; code 4409 displays explicit recovery and does not redial automatically. The guest service owns persistence; the phone never chooses a shell, path or session.

Power controls use separate credential-free owner metadata `{mainID,requestID,gatewayURL}` and the main gateway's authenticated registry. Previously connected provisioned routes recover ownership only by matching a real registry row, not by guessing a VM from its URL. External gateways without registry ownership show power controls as unavailable. With capability `vm_control:true`, status uses `GET /api/plugins/bot-provisioning/v1/requests/{id}/vm`, power uses sibling `POST /power`, and receipts use `GET /power/{operation_id}`. The exact action and operation UUID are persisted before sending. An uncertain result offers refresh or retry of that same operation; new power actions require explicit user selection. Accepted receipts mean cluster acceptance; observed state supplies actual status. Stop remains available for a failed VM whose desired state is running. Start/stop/restart preserve the same VM and disk; navigation and reconnection never issue power actions.
