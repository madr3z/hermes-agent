# Dispatch design QA

final result: passed

Reviewed on 12 October 2026. This result covers local simulator rendering and the
available navigation flows. It does not establish connected gateway or physical
iPhone acceptance.

## Target and capture

Target: the user's selected Dispatch image. The expired clipboard copy was
replaced by its identical retained original, copied to `/Users/madrez/.codex/visualizations/2026/10/12/01a1319c-07eb-7411-bccb-695f5e3a1502/dispatch-review/source.png`
(853 × 1844 pixels).

Implementation: native SwiftUI in `DispatchTodayView.swift`, `DispatchStyle.swift`,
`DispatchCollections.swift`, and `DispatchAttention.swift`.

The reference fixture uses the account question and two canonical conversation
previews. The native UIKit host captures 390 × 844 points at 2× density
(780 × 1688 pixels), with system safe areas disabled to match the artwork viewport.
The source and native render are normalized to 390 × 844 for comparison.
System bars and safe areas were reviewed separately in the live app.

Evidence directory: `/Users/madrez/.codex/visualizations/2026/10/12/01a1319c-07eb-7411-bccb-695f5e3a1502/dispatch-review`.

| Evidence | Purpose |
| --- | --- |
| `comparison-final.png` | Full source and final native screen, side by side |
| `focus-hero.png` | Hero typography, subtitle, and branch crop |
| `focus-request.png` | Account question, detail, and primary action |
| `focus-navigation.png` | Composer shortcut and bottom navigation |
| `dispatch-reference-final.png` | Full native light fixture |
| `dispatch-dark-final.png` | Full native dark fixture |
| `dispatch-accessible-final.png` | Accessibility 3 text fixture |
| `live-today.png` | Installed app with native safe areas and honest empty state |
| `live-gateway-form.png` | Existing gateway form reached from Settings |

These files were opened and inspected. The fixture uses a real UIWindow and
`drawHierarchy`, so the capture includes UIKit-backed scroll content.

## Review and fixes

| Surface | Findings and final result |
| --- | --- |
| Typography | Georgia was too heavy and wide; Didot still wrapped the account question. Baskerville with adjusted tracking restores the two-line hero and one-line question/detail at the reference size. No text truncation in the default fixture. |
| Spacing and layout | Reduced hero and section gaps, action padding, and the gap between recent rows. Both recent rows remain visible above the composer shortcut. The masthead no longer fades under the iOS 26+ scroll edge effect. |
| Color and finish | Adaptive ivory, ink, forest, and rust retain the reference hierarchy. Secondary text is `#6B6E68` on `#F6F3ED` (calculated contrast 4.68:1). Dark mode has legible text, rules, icons, and actions. |
| Artwork | Adjusted the sage branch offset to show a connected stem rather than clipped, disconnected leaves. Transparency composites cleanly on both backgrounds. Artwork is decorative and hidden at accessibility text sizes. |
| Controls and content | Primary action, composer shortcut, and tabs have clear targets. Accessibility 3 text wraps and the body scrolls; the bottom shortcut and navigation remain visible. Real conversation previews and request states replace invented completion claims. |

Iteration evidence remains in `comparison-initial.png` and `comparison-v2.png`
through `comparison-v4.png`. The initial ImageRenderer capture omitted scroll
content and was rejected as invalid evidence. The corrected native capture exposed
the typography and fold issues above. The final capture closes those P2 findings,
including the recent-row gap found in v4. No actionable P0, P1, or P2 visual issue
remains in the reviewed scope.

Accepted differences: native SF Symbols; a new sage illustration rather than a
trace; flat adaptive paper and button colors instead of raster texture; small
native font and glyph differences; a localized live date; and recent conversation
labels/icons rather than unsupported task-completion status. The composer-looking
shortcut opens the real conversation composer. It does not pretend to send a home
screen message. These are deliberate product adaptations, not pixel identity.

## Live interaction review

On Hermes Dispatch QA (iPhone 17e, iOS 27.0), verified Today → Chats → Bots → Today,
Settings, disabled Create Bot without a controller, Settings → Connect a gateway,
Cancel → Today, Today → Connect to Hermes, and Cancel → Today. Native accessibility
reported the expected labels, selected tabs, and disabled sign-in state. The app
remains open on Today. No credentials were entered or gateway request submitted.

The connected account/request and draft ownership paths were checked by native
unit tests. Live account submission, a real connected conversation, and back
navigation from that conversation require a gateway fixture or credentials and
are not claimed here.

## Tests and recovery

- Swift package: **102 tests, zero failures**.
- Focused native iPhone suite: **7 tests, zero failures** (`DispatchTests`,
  `ChatRequestsStoreTests`, and `ChatLoginControllerTests`).
- Repository checks: **11 checks passed**.
- `git diff --check`: passed.

The simulator initially stalled during installation and XCTest connection.
Restarting CoreDeviceService restored install, launch, and screenshots; the
supported DeviceHub Restart on the isolated QA simulator restored XCTest.
No simulator data was erased and no Mac reboot was needed. This is the observed
recovery sequence, not a proven diagnosis of the underlying Apple service bug.
See `VALIDATION.md` for commands and preserved diagnostics.
