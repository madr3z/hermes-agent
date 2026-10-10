# Native iPhone validation — 10 October 2026

Checkout: `/Users/madrez/.codex/worktrees/hermes-iphone/hermes-agent`
Branch: `codex/hermes-iphone`
Toolchain: Xcode 27.0 (27A266a), Swift 6.4.0
Minimum deployment: iOS 17.0

## Passed

- `swift test --package-path apps/ios --scratch-path /private/tmp/hermes-iphone-build/swift-tests`: **12 tests executed, 0 failures**, including the TLS/text-WebSocket integration fixture (6.198 seconds, final run at 23:42 BST). This is a macOS-hosted native transport test, not a real gateway/model acceptance run.
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

Voice submission without a persisted user-row receipt (queued/compute-isolated paths) is a known contract limitation: the task remains visible in Bot Chat, and the phone reports that it cannot attribute its spoken result. It never guesses from generic completion events.

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
