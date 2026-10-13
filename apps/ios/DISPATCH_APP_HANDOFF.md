# Whole-app Dispatch implementation — 13 October 2026

Status: installed in place on MadPhone on 13 October 2026; normal launch succeeded.
The earlier capacity block is resolved. Signed binary source is
`875d0a31fbe0fb2ef0ef8f9e3747b9c719169e27`: production styling commit
`631864f83c8456a568178086edff11bc166804dc` plus a test-only capture correction.

Base: 29222637e820a91626adb93e411d26934e47b2b3 (installed combined call release).
Branch: codex/hermes-dispatch-whole-app.
Worktree: /Users/madrez/.codex/worktrees/9eb0/hermes-agent.

## Coverage

| App-owned surface | Dispatch implementation |
| --- | --- |
| Today, Chats, Bots | Existing Today art/hierarchy retained; Chats/Bots now use serif navigation headings and matching empty states/roster sections. |
| Chat and saved history | Serif bot/content headings, paper composer with paperclip, forest actions, matching upload/tool/code/file/activity/request/sign-in cards, saved history and command output. |
| App settings | Settings, gateway sign-in, call preferences, incoming-call/notification settings, and postponed-call form. |
| Bot management | Bot settings hub, creation, resource/login forms, provisioning state, and deletion review. |
| Accounts and connectors | Accounts, MCP setup/credentials/OAuth chrome, Google, iCloud, stdio, plugin catalog/install/review/settings/activation. |
| Skills and memory | Installed skills, hub, skill review/content, memory list/cards. |
| Models and tools | Model/usage list, selection sheet, enabled toolsets/current tools and disclosure content. |
| Tasks and delegation | Scheduled tasks, create/edit/details, recorded runs, subagent list/details/instructions. |
| Computer | Remote-view chrome, disconnected state, power controls, screen controls/help, and paste sheet. Remote desktop and terminal pixels remain the remote content. |
| Calls | The accepted responsive CallScreen/CallSummary from 292 is unchanged. Their settings and postponed-call banner now match the rest of the app. |

System-owned Photos/files pickers, sharing/Quick Look, consent pages and iOS
permission dialogs retain their native/provider UI. This change does not replace
or reimplement those flows.

## Shared design

DispatchPageStyle.swift supplies paper/ink/forest navigation, serif titles,
native List/Form/Section wrappers with wash rows and quiet rules, accessible
empty states, and primary/secondary action styles. These reuse DispatchStyle;
there are no new dependencies, settings, themes to select, or service calls.
All app-owned default form/list containers now use these shared components.

## Scope preservation

The production diff is presentation code only. Store/model/client files,
ChatComposer, ChatAttachmentImport, VoiceCall, CallScreen, call routing,
Info.plist, APNs, credentials, Keychain and backend code are unchanged. ChatView
keeps @State composerFocused, its native UITextView binding, cached chat owner,
existing Photos/import pipeline, and no extra Paste button. Action callbacks,
disabled conditions, confirmation dialogs, secure fields, tasks and persistence
remain intact. Existing call responsive fixes and opening speech are retained.
The previously reported Photos selection crash is separate and not claimed fixed.

## Validation

- git diff --check: passed during source review.
- Repository checks: all 11 passed; log retained as `source-checks.log`.
- Simulator compilation and focused native run: 2 tests passed, zero failures.
- All 13 captured screens were inspected; light/dark/Accessibility 3 form layouts
  and shared styling passed visual review. The synthetic chat fixture was corrected
  to deliver its final turn after layout; the changed test then passed again
  (1 test, zero failures), and its settled chat capture was inspected.
- Signed iPhone build passed. Strict codesign, original profile UUID, team, bundle
  ID, push-enabled setting, and exact entitlement equality with installed 292
  were verified before installation.
- In-place installation succeeded, database sequence 6472. One normal launch
  succeeded with terminateExistingInstances=false (process 13827).
- Capacity had previously blocked validation below 1 GiB. It recovered before
  this installation request: native validation started at 53.24 GiB and reached
  a minimum of 44.86 GiB; the signed build minimum was 41.22 GiB. The 2 GiB guard
  stayed enabled. No cleanup, service reset, simulator erase, or new device was
  used. Only the existing task-owned Dispatch build cache was used.

DispatchAppVisualTests contains two focused capture tests and thirteen actual
page captures at 390 x 844 points / 2x: gateway light/dark/accessibility3, Settings,
call settings, create bot, add MCP account, bot settings light/dark, connectors,
scheduled tasks, chat and saved chats. Stores use isolated defaults and no
endpoints, so client lookup stops before credentials/network access. Callbacks
are inert and raise-to-call is disabled in test-only preferences. Captures are
kept as xcresult attachments and print DISPATCH_APP_RENDER paths. These fixtures
were compiled and executed; they do not prove connected account/VM operations.
The settled chat is a synthetic connected-state presentation, not a gateway test.

## Installation and integration record

User explicitly requested installation in this design session. The validated app
was installed here without uninstalling or resetting the existing app. Original
profile `4b79f5e9-2a54-4d87-a591-0623483f1904`, team `2JHBG6HA8N`, application ID
`com.hermes.iphone`, APNs entitlement and Keychain access prefix are unchanged.
The retained 292 rollback app is untouched. No live model/call, real connector,
VM operation, Photos selection, or private content inspection was used.

Evidence and retained signed app:
`/Users/madrez/.codex/visualizations/2026/10/12/01a1319c-07eb-7411-bccb-695f5e3a1502/whole-app-review/`.
See `app-native-result.json`, `app-native.xcresult`, `chat-settled-native.xcresult`,
`visual-review.json`, `dispatch-app-*.png`, `signed-native-result.json`,
`signature-proof.json`, `phone-install.json`, `phone-launch.json`, and
`installation-receipt.json`. Initial captures remain separately retained.

On 13 October 2026, the user requested integration and session archive after
handover. The clean canonical checkout at
`/Users/madrez/developments/Projects/hermes-agent` on `codex/hermes-custom` was
fast-forwarded from `29222637e820a91626adb93e411d26934e47b2b3` to
`e11a2d622548e9d49cbd5da953efa8faf0d1665f`, preserving the authored production,
fixture and installation-record commits. This handover update is documentation
only. The installed binary still corresponds to `875d0a31fb`; no rebuild,
reinstallation, backend operation or remote push was required or performed for
integration. Tests that were already green were not repeated.

This file is the repository handover. A direct message to the Project Manager
thread was not sent: automatic approval review rejected that action because the
user had not explicitly authorized messaging that thread. The signed app,
screenshots, logs and receipts remain in the evidence directory above. Human
acceptance of connected flows and the separate open Photos incident remain
outside this installation proof. No further work on this design session is
required; preserve the evidence and existing rollback app.

## New shared components and fixtures

- `apps/ios/HermesPhone/DispatchPageStyle.swift`
- `apps/ios/HermesPhoneTests/DispatchAppVisualTests.swift`
- `apps/ios/DISPATCH_APP_HANDOFF.md`

## Changed presentation files

- `apps/ios/HermesPhone/AgentPluginView.swift`
- `apps/ios/HermesPhone/BotMemoryView.swift`
- `apps/ios/HermesPhone/BotModelView.swift`
- `apps/ios/HermesPhone/BotRoutinesView.swift`
- `apps/ios/HermesPhone/BotSkillHubView.swift`
- `apps/ios/HermesPhone/BotSkillsView.swift`
- `apps/ios/HermesPhone/BotToolsView.swift`
- `apps/ios/HermesPhone/BotToolsetsView.swift`
- `apps/ios/HermesPhone/CallPreferencesView.swift`
- `apps/ios/HermesPhone/ChatActivityView.swift`
- `apps/ios/HermesPhone/ChatCommandsView.swift`
- `apps/ios/HermesPhone/ChatFileCard.swift`
- `apps/ios/HermesPhone/ChatMessageView.swift`
- `apps/ios/HermesPhone/ChatRequestsView.swift`
- `apps/ios/HermesPhone/ChatView.swift`
- `apps/ios/HermesPhone/ConnectorForms.swift`
- `apps/ios/HermesPhone/ConnectorsView.swift`
- `apps/ios/HermesPhone/CreateBotView.swift`
- `apps/ios/HermesPhone/DispatchCollections.swift`
- `apps/ios/HermesPhone/GoogleAccountConnectorView.swift`
- `apps/ios/HermesPhone/HermesPhoneApp.swift`
- `apps/ios/HermesPhone/ICloudConnectorView.swift`
- `apps/ios/HermesPhone/LoginHandoffCards.swift`
- `apps/ios/HermesPhone/MCPOAuthView.swift`
- `apps/ios/HermesPhone/MobileContactView.swift`
- `apps/ios/HermesPhone/PhoneComponents.swift`
- `apps/ios/HermesPhone/PluginSettingsView.swift`
- `apps/ios/HermesPhone/RoutineOperationsView.swift`
- `apps/ios/HermesPhone/SavedChatsView.swift`
- `apps/ios/HermesPhone/StdioAccountConnectorView.swift`
- `apps/ios/HermesPhone/SubagentsView.swift`
- `apps/ios/HermesPhone/VMControlView.swift`
- `apps/ios/HermesPhone/VMDeletionView.swift`
