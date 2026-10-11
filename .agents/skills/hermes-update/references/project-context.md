# Custom Hermes context

This is a discovery map, not a current release lock. Resolve current state from
Git, installed build stamps, Infra declarations, and live read-only inventory.
Temporary handoffs and the October 2026 baseline can become stale.

## Behavior to preserve and compare with upstream

| Feature | Required behavior |
| --- | --- |
| GPT Live transcripts | Spoken user and assistant turns persist in canonical chat, including reopen/reconnect behavior. |
| Bot provisioning | Create Bot defaults to its own persistent Linux VM, with CPU/RAM/disk and explicit optional copying of allowed provider keys. Requests and retries use durable identities. |
| Linux login | Bot name is the actual Linux username. User chooses and confirms the VM password during creation. Controller login is separate; no plaintext password in persistent client state or logs. |
| Native iPhone | Same bots, chat, voice, provisioning, and VM controls; native controller sign-in and device-only Keychain storage. |
| Remote VM access | Full Linux screen, keyboard/mouse, persistent terminal, status/start/stop/restart in Mac and iPhone. Closing either client does not stop the VM or shell. |
| Private authentication | Main authentication proxies owned guest HTTP/WS access. Guest credentials remain server-side. Cookie sessions and single-use WS/display tickets retain their separate scopes. No public VNC/SSH. |
| Managed deletion | Explicit confirmation deletes the owned bot VM and files. Durable receipt recovery, ownership/UID guard, and server-confirmed deletion precede local roster removal. Unmanaged/pilot entries are not deleted by this path. |

Relevant Hermes areas include `apps/desktop`, `apps/ios`, `tui_gateway`,
`hermes_cli/web_routers`, and the real auth and GPT Live implementations. Find
actual symbols rather than assuming historical filenames. Provisioning, proxy,
guest-access plugins and cluster packaging live in the separate Infra repository.

## Discovery locations

- Canonical custom branch: `codex/hermes-custom`, in the primary checkout
  `/Users/madrez/developments/Projects/hermes-agent`. It combines all custom
  Hermes client/backend work and this skill. Keep `main` as the upstream baseline.
  Earlier feature branch names were consolidated; do not require them to exist.
  Infra plugins and deployment declarations remain in their separate repository.
- Infra checkout: `/Users/madrez/developments/Infra`. Read its AGENTS.md and
  current `services/hermes-bot-provisioner/deployment/README.md`, `API.md`,
  `REMOTE_ACCESS.md`, build tooling, source pins, and Flux declarations.
- Project delivery records:
  `/Users/madrez/.codex/visualizations/2026/10/10/01a127ad-c948-70f3-b349-ec55786574aa/`.
  Start with `hermes-delivery-status.md` and the newest relevant handoffs.
- Initial combined client source was `dcc429651a4fe9e7bbf3f2b14721f576cc29f153`
  in `/Users/madrez/.codex/worktrees/bot-vm-deletion/hermes-agent`.
  Its Mac artifact used `90529968f7684b924381415c06ae77205cc74d13`;
  its iPhone tree matched `fcbd57add377d0ba33da15900789eee60e243e0e`.
  These are recovery/discovery anchors, not instructions to deploy old code.
  The old managed checkout directories were removed when their chats were archived.
  The recovered Mac app is in the delivery-record directory under
  `hermes-mac-release/Hermes.app`, with an independent source clone alongside it.
  The local `hermes-source-recovery` bundle preserves the earlier branch tips;
  it requires the upstream prerequisite recorded in its proof and is not an
  off-machine backup.
- Initial runtime Hermes source was `d32cccd36a69d5d625d6c59e51d718d1c275a66b`.
  Infra deletion deployment completed at
  `6fe260dfc43379b552ce66eff11aaf857161897f`, with plugin source `59faf27`.
  This is historical evidence; recheck live versions. Do not treat an old
  approval packet or local candidate as proof of current deployment.
- Expected private main: `https://hermes-main.tailf69582.ts.net`.
  Expected controller namespace: `hermes-bot-control`; managed guests:
  `hermes-bots`; context: `infra-main-01`. Verify all against current declarations
  and the actual API endpoint before mutation. Keep the separate pilot excluded.
- Existing private image names: `ghcr.io/madr3z/hermes-main` and
  `ghcr.io/madr3z/hermes-bot-importer`. Use observed digest pins, not `latest`.

Do not embed credentials or temporary credential-file contents in this skill.
Use the current protected secret/recovery procedure. Preserve controller state,
VM disks, and existing encrypted backups. A retained PVC alone is not a backup.

The initial custom client work was combined locally, not merged into official
NousResearch Hermes. Verify durable remote backup and current branch ownership
before relying on local worktrees or archiving any release source.
