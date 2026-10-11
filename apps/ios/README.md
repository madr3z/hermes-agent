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

Enter the HTTPS main controller URL, username and password. The app discovers password-capable providers through `GET /api/auth/providers` and signs in through `POST /auth/password-login`. The password stays in transient form state. Only the returned secure, HttpOnly session cookies are saved in Keychain as `WhenUnlockedThisDeviceOnly`. Cookie sessions stay scoped to the exact controller host, port and path. Redirects outside that scope are refused. HTTP sends cookies without an Authorization header and saves rotated cookies after each response. Each WebSocket obtains a fresh single-use ticket from the main controller's `POST /api/auth/ws-ticket`.

Managed guests share their verified owning main session only when their authenticated registry identity and canonical proxy URL match. If a session expires, use **Sign in to controller** on that controller's roster section. Existing access-token connections remain supported through the Access token option. They use bearer HTTP auth and the existing WebSocket query-token contract. Invalid credentials are never saved as a working connection. Only labels, URLs, owner identities and non-secret provisioning retry settings enter preferences; credential-bearing URLs are never logged.

- `profiles.list(include_sessions:true)` supplies the roster.
- Opening a bot resolves `session.list(title:"Bot Chat",include_hidden:true,profile)` every time, resumes its `resolved_id`, and uses the returned **runtime** ID for later RPC calls.
- A missing registry row uses `session.create` plus eager `session.title`. A concurrent creator's registry winner is adopted before any prompt is sent. A failed lookup never creates a replacement chat.
- `prompt.submit` streams gateway events; Stop uses `session.interrupt`. Reconnection restores the authoritative transcript, including in-flight output. The app does not close sessions when leaving a screen or backgrounding; bot services and healthy work stay on the VM under existing server lifecycle policy.
- Unsupported server requests are left unanswered so a capable shared Desktop client can respond. The phone never approves them. The phone shows compact tool progress, native Markdown, fenced code and attachments. It does not approve server requests or edit sessions.

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

The request UUID and exact non-secret settings survive an uncertain send. Passwords stay in transient secure form state and never enter preferences or saved retry bodies. Accepted submission or leaving the form clears the password fields. Recovery and retries first GET the saved request ID. A found receipt recovers without a password. Only a 404 permits explicit re-entry of the original password and POST with the same UUID and settings. Other lookup failures block POST; a changed password or body receives the server's generic 409. A controller without the Linux account capability cannot create a new bot from this form. Ready results supply `{id,label,base_url,profile:"default"}`; the phone accepts only the same-origin provisioning proxy path. The main session stays in Keychain and is used to access that proxy; no guest token is returned to the phone.

A missing plugin or unavailable service is shown as unavailable, not as a created VM. The running Infra pilot is not changed by this client implementation.

## Acceptance boundaries

See `VALIDATION.md` for exact build/test evidence. Simulator launch cannot establish physical microphone, Bluetooth/speaker routing, barge-in quality, background recovery on a real mobile network, device signing or TestFlight acceptance. Live gateway/VM provisioning and provider voice calls require the configured private HTTPS proxy and a deliberate live acceptance run.

## VM screen, terminal and power

Open **VM controls** from a bot's chat toolbar. The surrounding roster, chat, voice and VM controls remain native SwiftUI; the two focused remote surfaces use bundled [renderer sources](RemoteRenderers/README.md). Portrait and landscape are supported. Screen is initially view-only. **Take control** uses the guest's existing human/agent lease; **Hand back** relinquishes it. Touch supports pointer movement, dragging, right click and scrolling. Use Keyboard, Ctrl, navigation keys, Fit/1:1, Pan and explicit Paste for remote work. Leaving or backgrounding the view closes its attachment without stopping the guest or terminating its desktop/shell.

The main gateway proxy must support sibling `/api/display/ws` and `/api/terminal/ws` under the registered guest route. Native WSS uses a fresh main controller ticket for cookie sessions, or the existing main query token for access-token connections. Display also sends the independent single-use guest `display_ticket`. These authenticated URLs stay in URLSession and never enter JavaScript, preferences, debug output or navigation. RPC event listeners coexist with chat, bind to the gateway client plus `profile_key`, and compare the human lease's viewer hash. Abnormal transport/RPC failures close with 1011, preserving the lease; intentional departure closes with 1000. A viewer ID is reused only while its original RPC owner remains connected.

Terminal requires `/api/terminal/status` with `available:true` and `protocol:hermes-terminal-v1`. Binary output is raw UTF-8/ANSI; binary input is keyboard bytes, with JSON text resize frames. It attaches to the guest's fixed `default` tmux session as the Hermes user in its workspace. Reconnect restores the same session. A newer attachment owns input; code 4409 displays explicit recovery and does not redial automatically. The guest service owns persistence; the phone never chooses a shell, path or session.

Power controls use separate credential-free owner metadata `{mainID,requestID,gatewayURL}` and the main gateway's authenticated registry. Previously connected provisioned routes recover ownership only by matching a real registry row, not by guessing a VM from its URL. External gateways without registry ownership show power controls as unavailable. With capability `vm_control:true`, status uses `GET /api/plugins/bot-provisioning/v1/requests/{id}/vm`, power uses sibling `POST /power`, and receipts use `GET /power/{operation_id}`. The exact action and operation UUID are persisted before sending. An uncertain result offers refresh or retry of that same operation; new power actions require explicit user selection. Accepted receipts mean cluster acceptance; observed state supplies actual status. Stop remains available for a failed VM whose desired state is running. Start/stop/restart preserve the same VM and disk; navigation and reconnection never issue power actions.

## Delete a managed bot and its VM

A controller advertising `vm_delete:true` enables **Delete Bot and VM** for its registered VM connections and provisioning requests. This includes an offline guest or a failed/incomplete creation. Unmanaged gateways and the pilot have no VM deletion action. The confirmation states that the bot stops and its VM, workspace and files are removed permanently; existing backups remain.

The phone uses the existing owning main client/session, including its normal HTTP cookie handling. After confirmation it saves a stable operation UUID and the exact registered bot name before `POST /api/plugins/bot-provisioning/v1/requests/{id}/delete` with `{operation_id,confirm_name}`. Loading and polling only read status/receipts. Recovery reads sibling `/delete/{operation_id}` first; only a 404 permits an explicit resend of the same body/UUID. A failed receipt requires explicit confirmation of a fresh operation. Queued/deleting/failed receipts retain the local connection. Only a matching `deleted` receipt removes that VM's local endpoint and copied gateway credential. The main login, pilot and other connections remain.

## Native chat attachments

Use the composer’s **Photos** or **Files** action. Selections stay in memory until Send. Attach up to five files, with a combined size of 10 MiB. Photos are converted to JPEG. HEIC/HEIF images selected from Files are also converted to JPEG. Other files retain their bytes. Removing a selection before Send does not contact the gateway.

Uploads use the current Bot Chat runtime and profile. `file.attach` stages bytes and supplies the exact server reference. Photos then use `image.attach` with that known gateway path; this permits `image.detach` cleanup even when an image-registration acknowledgement is lost. A rejected send retains its draft and staged receipts. An uncertain send is not replayed; refresh the authoritative transcript before choosing a new message. Reconnection clears only confirmed image staging, and upload receipts never cross a runtime change.

Message cards recognize local `@image:`, `@file:`, `MEDIA:` and Markdown file links outside code fences. Code examples stay literal. Images, documents and generated artifacts download through the authenticated owning client at `GET /api/fs/download?profile=…&session_id=…&path=…`. The session ID is the persisted stored ID. Quick Look and Save or Share receive only a protected local temporary file, which is removed when its card leaves the screen. Downloads refuse redirects and files over 25 MiB. Remote web links remain links.

The controller’s provisioning proxy must explicitly support the download route and its three query fields. A gateway implementing this API does not establish that an older deployed proxy forwards it. Missing proxy support appears as a download error. The current upload limit fits the deployed 16 MiB WebSocket frame cap after base64 encoding. These features require integrated builds and real device acceptance; no additional signing capability is needed for PhotosPicker, Files, Quick Look or sharing.

## Account-scoped stdio connectors

Connectors includes an iCloud preset and a custom stdio account form. Each account has a distinct MCP name and process. Credential values use fresh UUID-scoped `MCP_<ACCOUNT>_<UUID>_<KEY>` slots in the owning bot's `.env`; `config.yaml` contains only their `${…}` references. The phone keeps submitted credentials only in transient setup state. A partial credential failure offers an explicit retry for the same slots. An uncertain server add cannot replay. Closing an incomplete setup can leave unused secret slots; manage those from the Mac. Existing accounts and credentials are never replaced by setup.

The iCloud preset uses [ThomasCrouzet/icloud-mcp](https://github.com/ThomasCrouzet/icloud-mcp/tree/8cf9a4f86c6af36f4e6121d8b0e93806611036e9), MIT, pinned to `8cf9a4f86c6af36f4e6121d8b0e93806611036e9`, at `/opt/hermes-connectors/icloud-mcp`. Install or update that runtime on each VM separately. Saving the preset does not install it. Test connection provides live evidence only when the user runs it successfully.

Calendar and Mail reads are enabled; Contacts are disabled. Read-only is the default and disables all changes, including mail sending. Calendar writes and Mail changes require explicit controls. Sending mail has a separate control and requires exact recipient addresses or an explicit Allow all recipients choice. App-specific passwords stay in the secret store. The custom form uses secure fields for each process environment value and supports independent accounts with the same process environment names.
