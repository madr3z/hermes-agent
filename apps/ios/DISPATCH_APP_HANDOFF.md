# Whole-app Dispatch implementation — 13 October 2026

Status: source implementation complete; native build and visual review blocked
by the existing 2 GiB free-capacity floor. Do not call the new screenshots or
runtime checks passed. No native job has been launched for this change.

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
- Compilation, new visual fixtures and tap-through: NOT RUN.
- Free capacity started at 3,744,000 KiB, then fell to 1,193,640 KiB and below
  1 GiB before any native job was attempted. No deletion, simulator reset,
  install, build, test or shared-cache mutation was used to bypass the floor.

DispatchAppVisualTests contains two focused capture tests and thirteen actual
page captures at 390 x 844 points / 2x: gateway light/dark/accessibility3, Settings,
call settings, create bot, add MCP account, bot settings light/dark, connectors,
scheduled tasks, chat and saved chats. Stores use isolated defaults and no
endpoints, so client lookup stops before credentials/network access. Callbacks
are inert and raise-to-call is disabled in test-only preferences. Captures are
kept as xcresult attachments and print DISPATCH_APP_RENDER paths. These fixtures
are uncompiled and unexecuted; they do not prove connected account/VM operations.

## Next integration gate

Recheck capacity and exclusive simulator/build ownership. With sufficient
headroom, compile and run only DispatchAppVisualTests on the existing app target
and FA701042-454F-4E7E-A97F-21068AB4F7D4 simulator using the task-owned Dispatch
cache if suitable. Do not use the pending Photos keyboard cache. Inspect every
new capture, including form section grouping, row colors, long titles, disabled
buttons and accessibility scrolling. Add focused interaction checks if a render
or current behavior shows a problem. Do not repeat prior green release suites.
Root retains combined release/install ownership. The installed release remains
292 until a separately validated in-place install.

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
