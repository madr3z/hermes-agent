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

Enter an HTTPS gateway base URL and its access token. Tokens are stored in Keychain as `WhenUnlockedThisDeviceOnly`; only gateway labels/URLs and provisioning retry bodies are stored in preferences. An invalid token is never saved as a working connection. The WebSocket follows the existing `serve` query-token contract; no credential-bearing URL is logged. HTTP uses bearer auth.

- `profiles.list(include_sessions:true)` supplies the roster.
- Opening a bot resolves `session.list(title:"Bot Chat",include_hidden:true,profile)` every time, resumes its `resolved_id`, and uses the returned **runtime** ID for later RPC calls.
- A missing registry row uses `session.create` plus eager `session.title`. A concurrent creator's registry winner is adopted before any prompt is sent. A failed lookup never creates a replacement chat.
- `prompt.submit` streams gateway events; Stop uses `session.interrupt`. Reconnection restores the authoritative transcript, including in-flight output. The app does not close sessions when leaving a screen or backgrounding; bot services and healthy work stay on the VM under existing server lifecycle policy.
- Unsupported server requests are left unanswered so a capable shared Desktop client can respond. The phone never approves them. This initial client does not render desktop-only tools, attachments, approval/clarification dialogs or session editing.

## GPT Live

Native WebRTC audio uses the gateway's existing `POST /api/audio/voice-live/session?profile=…` SDP exchange. The provider key stays on the gateway. An audio track and `oai-events` data channel handle full-duplex speech, provider-side barge-in, mute and close. `session.delegation.created` submits the latest spoken user request to the same bot runtime with bounded spoken context; task output returns through `session.commentary.append` only when its persisted user-row receipt matches the active delegation. Superseded task completions are ignored. The phone waits for an interrupted voice task to become idle before submitting its replacement. If a queued or compute-isolated submission supplies no receipt, the task remains visible in Bot Chat and the phone reports that it cannot safely attribute spoken results.

Persistence requires `voice.live.transcript.list` and `.append` on the backend. Calls fail before microphone acquisition if that contract is missing. Fragments retain stable call/event/utterance IDs, are retried idempotently, and upsert full accumulated display messages by `display_metadata.voice_message_id`. Unsynced fragments use an atomic local outbox protected with iOS complete file protection, retried after canonical resume. A call stops when its sheet closes or the app backgrounds; the bot's delegated task continues on the gateway. Pending-transcript failures remain visible.

Native audio dependency: [stasel/WebRTC](https://github.com/stasel/WebRTC), M154 (`154.0.0`), pinned to Git revision `0c0ad84dac6c1941c16a414dfcfba94691866e4c`. Its binary artifact is checksum-pinned by that package (`a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16`). This is a community distribution of Google WebRTC, not an Apple or OpenAI SDK. Its BSD-3-Clause license is included in the app's resources as `WebRTC-LICENSE.txt`. The package supplies device arm64 and simulator arm64/x86_64 slices.

## Create Bot

The main gateway needs the provisioning plugin:

- `GET /api/plugins/bot-provisioning/v1/capabilities`
- `POST /api/plugins/bot-provisioning/v1/requests`
- `GET /api/plugins/bot-provisioning/v1/requests`

The form consumes backend CPU/memory/disk bounds and defaults. Copy Credentials is off by default and copies server-side allowlisted provider API keys only. The request UUID and exact body survive an uncertain send. Ready results supply `{id,label,base_url,profile:"default"}`; the phone accepts only the same-origin provisioning proxy path. The main token stays in Keychain and is used to access that proxy; no guest token is returned to the phone.

A missing plugin or unavailable service is shown as unavailable, not as a created VM. The running Infra pilot is not changed by this client implementation.

## Acceptance boundaries

See `VALIDATION.md` for exact build/test evidence. Simulator launch cannot establish physical microphone, Bluetooth/speaker routing, barge-in quality, background recovery on a real mobile network, device signing or TestFlight acceptance. Live gateway/VM provisioning and provider voice calls require the configured private HTTPS proxy and a deliberate live acceptance run.
