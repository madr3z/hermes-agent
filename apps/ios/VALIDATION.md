# Native iPhone validation — 10–11 October 2026

Checkout: `/Users/madrez/.codex/worktrees/hermes-iphone/hermes-agent`
Branch: `codex/hermes-iphone`
Toolchain: Xcode 27.0 (27A266a), Swift 6.4.0
Minimum deployment: iOS 17.0

## Initial chat and voice baseline

- `swift test --package-path apps/ios --scratch-path /private/tmp/hermes-iphone-build/swift-tests`: **14 tests executed, 0 failures**, including the TLS/text-WebSocket integration fixture (final correlation run passed at 23:58 BST on 10 October). This is a macOS-hosted native transport test, not a real gateway/model acceptance run.
- Simulator compilation and link succeeded for arm64 and x86_64. A missing embedded-framework runpath was corrected; installation and runtime launch succeeded, and the native roster screen was visually verified. The final reviewed source compiled and linked successfully at 23:45 BST.
- WebRTC M154 source revision and binary SHA-256 match the pinned package. The framework supplies native simulator and device slices. Xcode's stalled download was recovered by populating its standard SwiftPM artifact cache with the independently checksum-verified exact artifact; no shipped dependency or TLS policy changed.

Covered behaviors: profile-qualified canonical registry lookup, compression-tip resume, failed registry never creating a replacement, concurrent canonical creation adopting its winner, HTTPS-only endpoints, encoded WS query token, HTTP bearer auth, proxy path/port preservation, server error propagation, live text-frame stream delivery, reconnect to the same canonical stored ID, accumulated voice-row upsert without replay duplication, global reclamation/invalidation ownership, slow-handler heartbeat bypass, shared Desktop approval coexistence, and superseded/early voice completion attribution.

- Repository `python3 scripts/check --staged`: **all 11 checks pass**, including zero code-health findings after the fixture corrections. The final staged snapshot is checked again before commit.

## Review regressions

| Finding | Fix and verification |
| --- | --- |
| Heartbeat stalls behind a slow RPC | `GatewayClient.checkLiveness` uses transport-bypass `gateway.ping`; real TLS wire fixture checks a 0.2-second heartbeat while another handler takes 0.5 seconds. |
| Global reclamation / registry changes get dropped | `ChatEventRoute` handles payload runtime IDs and profile-scoped/global invalidations; `ChatStore` re-resolves canonical ownership while retaining its draft. `testGlobalReclamationAndInvalidationStayScopedToCurrentOwner` covers event routing. |
| Phone error response races capable Desktop approval | Unsupported server requests remain unanswered. The wire fixture attaches a second client and verifies its delayed approval response wins. |
| Interrupted voice task A completes during task B | `VoiceDelegationTracker` requires the active delegation's persisted user-row receipt. `testSupersededSpokenTaskNeverSpeaksUnderNewDelegation` and `testVoiceCompletionBeforeSubmitAcknowledgementKeepsItsIdentity` cover stale results, late ACKs and early completions. |

The follow-up adds `client_turn_id` end-to-end matching on mobile, coordinated with the integration owner's backend extension. The real TLS/WebSocket fixture queues A then B without row receipts and sends late A, unrelated, missing-token, exact B and duplicate B completions; only B is returned for speech. It also verifies legacy validation fallback dispatches exactly once. Unit tests cover completion before ACK, a reused provider delegation ID across calls, and no retries after timeout, unrelated errors or accepted queue ACKs.

Older backends retain the immediate persisted-row fallback. Queued/isolated execution on an older backend without correlation stays visibly unsupported; results are never guessed from text or timing. The follow-up simulator and unsigned device builds both pass (`build-correlation.log`, `device-build-correlation.log`), as do all 11 repository checks (`check-correlation.log`). The wire fixture does not establish a full real backend/model integration run.

## Native build evidence

- Final simulator compile/link: **BUILD SUCCEEDED**. Installed and launched on iPhone 17e / iOS 27 simulator (`com.hermes.iphone`, PID 95838).
- Final unsigned iPhone arm64 compile/link: **BUILD SUCCEEDED**. This establishes device-target compilation, not signing or physical-phone execution.
- The native roster was visually verified on the simulator. Simulator launch/scene setup was slow on this host. Screenshot artifacts: `/private/tmp/hermes-iphone-build/hermes-roster.png` and the final relaunch capture beside it.
- Documentation path check and `git diff --check` pass.

## Not established

- Tap-through UI: computer-use native service failed to start; the native roster was visually verified, but no interaction was automated.
- Device signing, installation on a physical iPhone, microphone/speaker/Bluetooth routing, provider GPT Live audio/barge-in/delegation, and mobile background/reconnect acceptance.
- Real HTTPS gateway/proxy connection and VM creation. The existing Infra pilot exposes only its approved SSH/loopback path; this work did not export its token, create a public route, alter the pilot, or spend model/VM resources.
- Publication, CI, TestFlight and App Store distribution.

Logs and diagnostic artifacts are under `/private/tmp/hermes-iphone-build/`. The local TLS fixture trusts only its own ephemeral certificate in the test target; the app retains ordinary system trust.


## Remote VM follow-up — 11 October 2026

- Final complete Swift package run: **19 tests, zero failures**, at 01:12 BST (`remote-swift-final.log`). The real TLS WSS fixture enforces the production query-token seam independently of Authorization headers, preserves the guest display ticket and proxy prefix, transports binary RFB/PTY and keyboard bytes, sends text resize, observes 1011 on abnormal departure versus 1000 on intentional closure, and proves remote observers coexist with chat events. Ownership tests reject unmatched/foreign registry rows, missing request identities and edited endpoints; captured owner metadata survives encoding.
- Native arm64 iPhone17e/iOS27 simulator tests: **five targeted tests passed**, at 01:17 BST (`remote-native-final.log`). These exercise delayed connection after departure, independent terminal attachment when the desktop stops, Stop recovery for a failed VM, actual bundled WKWebView terminal startup geometry and visible ANSI text, and native HTTP/preferences power persistence before POST plus timeout/relaunch/explicit retry. A failed status refresh cannot authorize a fresh operation UUID.
- The focused screen test then **passed**, at 01:20 BST (`remote-screen-final.log`): real local WKWebView with the production exact-document navigation policy and CSP, native-channel RFB version/security/server initialization, a 1024×768 guest clipped to the phone at 1:1, and Pan enabled. noVNC needs `clipViewport:true` for local panning when Fit is disabled; Fit automatically disables clipping. These six native cases passed across focused runs, not a claimed live guest acceptance run.
- Renderer assets reproduce through `npm ci --ignore-scripts --no-audit --no-fund` and `npm run build` from their exact lockfile. Their source and license notices ship with the app. No server URL, token or remote content enters JavaScript as executable code.
- `python3 -u scripts/check --staged`: all **11 checks passed**, zero code-health findings. The final documentation/source snapshot is checked again before commit.

The first renderer harness run exposed a 30-second cold WebKit startup timeout and an off-window paint assertion; the harness now attaches to the real simulator key window, allows 60 seconds for cold initialization, and waits for paint before checking text. A second fixture error fulfilled an initial-resize expectation more than once on legitimate later resize notifications; the first notification is now observed once. Assertions were retained, and the actual renderer tests passed. Xcode verbose failure diagnostics caused lengthy cleanup stalls; subsequent focused runs use `-collect-test-diagnostics never` and exit normally. The Python wire fixture now resolves Python on PATH instead of Apple's developer-tool launcher, which timed out while the failing Xcode diagnostic run was active.

Simulator tap-through remains unverified: the computer-use native pipe still fails to start. Test-runner WebKit execution and screenshots establish renderer behavior, not physical touch, software keyboard/IME, mobile connection or real VM acceptance. The private proxy/guest plugin and VM lifecycle service require the other owners' integrated runtime. No VM power action or real shell command was sent by these fixtures. Device/signing readiness is inspected separately after the source commit.
