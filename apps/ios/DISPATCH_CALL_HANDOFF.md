# Dispatch call presentation handoff — 13 October 2026

Status: source implementation complete; native validation capacity-blocked.

## Source and scope

- Worktree: `/Users/madrez/.codex/worktrees/9eb0/hermes-agent`.
- Fresh branch: `codex/hermes-dispatch-calls`.
- Exact base: `0211c8227f69072dbaf436fff9ff7a704ad2d880`, the installed combined source
  supplied by the coordinator. The worktree was clean before switching.
- Previous design branch `codex/hermes-dispatch-redesign`, its author commits,
  handoff, and captured QA remain preserved.
- Implementation commit: identify with `git log -1` on this branch. This document
  is included in the same bounded commit as the two source files below.

Changed files:

1. `HermesPhone/CallScreen.swift`: presentation only, including CallSummary.
2. `HermesPhoneTests/DispatchCallVisualTests.swift`: synthetic visual fixtures.
3. `DISPATCH_CALL_HANDOFF.md`: this integration record.

The screen reuses DispatchStyle's adaptive paper, ink, forest, rust, wash, rules,
and Baskerville. It adds a left-aligned bot heading, a quiet reason panel, labelled
transcript cards, and matching controls. Answer and Start call use forest; Decline
and End call use rust. The reason sheet and minimized call summary share the same
palette. No branch artwork, animation, dependency, runtime, or app target was added.

## Preserved behavior and source review

- Existing ringing / active-or-connecting-or-preparing / start / close branches.
- All start, answer, ring-later, end, close, and minimized-return callbacks.
- Mute dispatch and its disabled state before active; receiver/speaker/accessory
  menu actions and accessory iteration. Audio output now also has an accessible
  value; no audio configuration changed.
- Status text and live timer conditions. Reason text, full-reason presentation,
  and the existing two/four-line policy.
- Both speaker labels, selectable transcript text, lazy scroll container,
  drag-to-pause following, Latest, and scroll-on-new-turn callbacks.
- Error and transcript-persistence status conditions and strings.
- Existing VoiceCall, IncomingCallView, VoiceView, MobileContact, call routing,
  opening speech, lifecycle, foreground behavior, and correlated hang-up code are
  untouched. The keyboard fix, Photos code, credentials, and Info.plist are untouched.

Close's full-width 48-point frame, fill, and content shape are inside its Button
label, so the visible control participates in hit testing. Latest and Read full
reason use 44-point labels. Decorative waveform and masthead/reason overlines are
hidden at accessibility text sizes. Existing vertical accessibility control
layouts and the full spoken reason label remain.

Source diff was inspected against 0211; `git diff --check` passed. No previous green
suite was rerun. No compiler or test success is claimed for this extension.

## Capacity gate and unverified layout

`df -k` reported 1,624,000 KiB available (about 1.55 GiB); another read during work
reported 1,536,000 KiB (about 1.46 GiB). Both are below the coordinator's hard 2 GiB
native build/test floor. No native build, test, install, screenshot, live call,
simulator operation, service reset, device creation, asset seeding, cleanup,
personal Photos inspection, clipboard access, or cache reuse was performed.
`/private/tmp/hermes-keyboard-native-build` was not opened or changed.

**All new layout is unrendered. Compact-height / landscape and accessibility-size
layout are explicitly unverified**, including transcript space below the reason
panel and above the stacked controls. Also unverified: new full-width Close hit
testing, dark-mode rendering, the reason sheet, long bot names, route menu labels,
and minimized-summary wrapping. Existing home-design captures do not validate
this call extension. Do not mark visual QA passed or install as accepted on this
source review alone.

## Focused next validation for integration owner

When capacity and simulator ownership permit, use the existing app/test target and
isolated simulator `FA701042-454F-4E7E-A97F-21068AB4F7D4` (iPhone 17e, iOS 27.0).
Recheck free capacity immediately before the native job. Do not use the pending
Photos build cache. No native command was executed or queued by this session.

The new `DispatchCallVisualTests` contains two capture tests and ten PNG/xcresult
attachments: incoming, preparing, outgoing-ready, active, muted-dark, reconnecting,
ended, incoming-accessible, active-accessible, and minimized. It uses a real UIKit
window at 390 × 844 points / 2× density and retains native safe areas. It creates
local VoiceCall objects and synthetic transcript events, with no gateway, outbox,
microphone, or audio route opened. Callbacks are inert. Generated files print as
`DISPATCH_CALL_RENDER` and use `dispatch-call-<state>.png` in app temporary storage.
The fixtures have not been compiled or run.

After integrating this commit onto the coordinator's current release, compile and
run the focused visual fixtures and existing `CallScreenTests`. Inspect the actual
renders and compact-height layout. Then verify available controls, reason sheet,
transcript following/Latest, full-width Close, and minimized Return/End without a
live call. Real audio/route and physical-device acceptance remain separate.

Root retains merge, combined validation, release, and installation ownership.
The reported Photos crash remains OPEN and separate.
