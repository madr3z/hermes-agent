# Dispatch integration handoff — 12 October 2026

Status: complete for integration. The accepted redesign and existing green QA are
preserved. No merge, phone install, simulator reset, or additional build/test run
was performed for this handoff.

## Exact source

- Worktree: `/Users/madrez/.codex/worktrees/9eb0/hermes-agent`.
- Branch: `codex/hermes-dispatch-redesign`.
- Base: `33352cef894ef86e7858545295e9ddd6b6bf55f6` (native long-press Paste).
- Authored implementation commit: `71f5a4dcbcb0fdca5d11badc3ea5ccc061152776`.
- The subsequent commit contains only this handoff. `git log -2` identifies it.
- Integration owner's supplied source: `d75ba4dc905c88ef090c6f9e7db65c817fa45ace`
  in `/private/tmp/hermes-continuity-recovered-20261012`.

Cherry-pick the implementation commit onto the integration owner's source; do
not replace the combined tree with this branch or merge its older base wholesale.
Retain commit authorship. This branch has not imported the continuity changes.

## Changed files in implementation commit

- `apps/ios/HermesPhone/Assets.xcassets/Contents.json`
- `apps/ios/HermesPhone/Assets.xcassets/DispatchBranch.imageset/Contents.json`
- `apps/ios/HermesPhone/Assets.xcassets/DispatchBranch.imageset/branch.png`
- `apps/ios/HermesPhone/ChatStore.swift`
- `apps/ios/HermesPhone/ChatView.swift`
- `apps/ios/HermesPhone/DispatchAttention.swift`
- `apps/ios/HermesPhone/DispatchCollections.swift`
- `apps/ios/HermesPhone/DispatchStyle.swift`
- `apps/ios/HermesPhone/DispatchTodayView.swift`
- `apps/ios/HermesPhone/HermesPhoneApp.swift`
- `apps/ios/HermesPhone/LoginHandoffCards.swift`
- `apps/ios/HermesPhone/PhoneStore.swift`
- `apps/ios/HermesPhoneTests/DispatchTests.swift`
- `apps/ios/README.md`
- `apps/ios/Sources/HermesGateway/Wire.swift`
- `apps/ios/VALIDATION.md`
- `apps/ios/design-qa.md`

## Accepted behavior

Today opens first with the selected serif/ivory/forest design and sage artwork.
Chats uses canonical previews; Bots retains gateway and VM management. Settings
retains controller, notification, and creation flows. Needs you summarizes only
current unanswered requests/account actions from already-opened chats. Tapping
opens the owning chat and leaves submission/confirmation to the existing flow.
No fake completed-work claims or background session creation were added.
The home message shortcut opens the real composer. The current chat retains its
draft while it remains the active bot on its endpoint.

## Conflict-sensitive integration

1. **`HermesPhoneApp.swift`**: both sources change RosterSheet and RosterView.
   Keep Dispatch `settings`, selectedTab, Today/Chats/Bots, tab bar, and retained
   Bots management. Keep continuity's `calls` case, RaiseToCallController state,
   foreground configure, environment injection, error alert, and call preferences
   presentation. Today hides the navigation bar, including its plus menu: add the
   call-settings callback/entry to `DispatchSettingsView` so default-agent and
   raise-to-call preferences remain reachable from Today Settings.
2. **`ChatView.swift`**: retain Dispatch's cached ChatStore initializer and task
   registration, paper background, and navigation-bar color. Retain continuity's
   RaiseToCallController environment, visibility tracking, obscuresChat logic,
   and show/hide callbacks. Urgent fix `c64c486c57e156c3c33c5f28cbe74b4dfc1d3f67`
   is already present in the supplied d75 source: **`composerFocused` must stay
   `@State private var composerFocused = false`**. This redesign commit does not
   change that declaration; its base still has the older @FocusState declaration.
   Do not copy the whole ChatView from this branch. Keep native UITextView
   long-press Paste and the existing Binding; add no extra Paste button or
   SwiftUI `.focused` modifier. Keep the urgent composer's regression tests.
3. **`ChatStore.swift`**: add the shared `login = ChatLoginController()` beside
   the existing stores. Keep continuity's `startVoice(preferReceiver:)` signature
   and receiver parameter forwarding. `LoginHandoffCards` uses that same login
   controller; retain its existing context invalidation behavior.
4. **`PhoneStore.swift` / ChatStore lifetime**: Dispatch retains one active chat
   per endpoint because that gateway client has one current chat owner. Same-bot
   entry reuses its draft; switching bots on that endpoint replaces the cache.
   Controller disconnect and VM deletion remove the retained entry. Keep the
   continuity owner/profile checks, voice history, and explicit foreground rules;
   avoid introducing a second cached chat owner during notification/call routing.
5. **Wire and docs**: preserve Bot `conversationPreview` and `lastActive`, which
   read only canonical_session metadata; keep existing preview fallback for Bots.
   Combine the appended README sections. Do not overwrite continuity validation.
   The final release needs its own combined-source validation evidence.

No redesign changes touch CallScreen, VoiceCall, VoiceAudioConfiguration,
RaiseToCall, CallPreferencesView, VoiceCallEndRequest, or Info.plist.

## Existing QA — do not rerun for handoff

- Swift package: **102 tests, zero failures**.
- Focused iPhone suite: **7 tests, zero failures**: DispatchTests (3),
  ChatRequestsStoreTests (2), ChatLoginControllerTests (2).
- Repository checks: **11 checks passed**. Final source/doc check exited 0.
- `git diff --check` passed before the implementation commit.
- Native light, dark, and Accessibility 3 fixture captures inspected. Typography,
  scroll-edge fade, artwork crop, and recent-row spacing were corrected.
- Live simulator: Today → Chats → Bots → Today; Settings; disabled Create Bot with
  no controller; both gateway-form routes; Cancel → Today. No credentials entered.

Visual evidence:
`/Users/madrez/.codex/visualizations/2026/10/12/01a1319c-07eb-7411-bccb-695f5e3a1502/dispatch-review/`.
Start with `comparison-final.png`, `dispatch-dark-final.png`,
`dispatch-accessible-final.png`, and `live-today.png`. Focus crops, source image,
and gateway-form capture are retained there. `design-qa.md` records the review.

Logs and the completed native result bundle:
`/Users/madrez/.codex/visualizations/2026/10/12/01a1319c-07eb-7411-bccb-695f5e3a1502/simulator-diagnostics/`.
Files: `hermes-dispatch-qa-final.log`, `dispatch-final.xcresult`,
`hermes-dispatch-swift-tests.log`, `hermes-dispatch-check-final.log`.
Exact commands and recovery sequence are in `VALIDATION.md`.

## Limits and next owner

The successful QA applies to the implementation commit above, not the combined
continuity release. Connected account submission, real gateway conversations,
physical-device execution, signing, CI, and release publication are not established.
The integration owner owns conflict resolution, combined validation, and the
requested phone installation. No shared cache or simulator action is needed to
consume this handoff. The isolated QA simulator remains available with Today open.
