---
name: hermes-update
description: Update this project's custom Hermes installation from upstream, resolve conflicts, identify upstream replacements for local features, rebuild affected clients, and deploy verified updates to the existing private cluster and managed bot VMs. Use when asked to update Hermes while preserving this project's custom features.
---

# Update custom Hermes and its deployments

Carry an update through source integration, affected checks, publication, cluster
rollout, and live verification. Do not stop at a plan or a successful Git merge.
Creating or editing this skill does not itself request an update.

## Scope and authority

A user request to run this update includes routine private image publication and
updates to the existing Hermes deployments using their established credentials,
capacity, private routes, and permissions. Carry forward applicable approval;
do not ask again for each ordinary build, push, or rollout. Prepare the concrete
diff and rollback before any consequential action.

Raise a concern before proceeding when an update requires destructive data
migration, loss of a custom feature, new credentials or broader permissions,
public exposure, additional paid capacity, or interruption of active bot work
that cannot be resumed. Complete independent work first. Ask only for the
specific uncovered decision. Do not delete bots or disks, recreate existing VMs,
rotate credentials, publish to the App Store, or change unrelated cluster services
as an update shortcut. Preserve the separate pilot unless the user includes it.

Use the simplest existing tools. No new updater service or periodic automation.
If delegation is requested or already authorized, use gpt-6.1-sol with high
reasoning for every worker. Do not reopen archived implementation chats merely
to update; their handoffs are reference material.

## Establish the actual baseline

Read repository and area AGENTS.md instructions. Read
[project context](references/project-context.md) for the feature inventory and
discovery paths. Verify every mutable path, revision, and deployment target.

Locate the current custom integration branch, its commits, the installed Mac
and iPhone build identities, and the Infra revision and running image digests.
The primary checkout can be upstream main without our features: it is not
automatically the release source. Check active work and do not race a current
deployment or edit another worker's checkout.

Record the before state and retain an immutable recovery commit and compatible
previous image/configuration. Preserve dirty work. Perform integration in an
isolated checkout based on the latest custom source. Inspect current upstream
remotes, release channels, commits, and release notes from authoritative sources.
Use the installed channel by default; do not silently switch to prereleases or
an arbitrary main tip. If this custom installation follows main, record the
exact fetched main SHA selected for this run.

## Run the update without dropping custom work

Inspect the current `hermes update` implementation and options before using it.
Its updater can switch a clean custom branch to the configured upstream branch,
or reset diverged history. A recovery ref does not mean our features remain in
the running build.

Use `hermes update` only in the isolated integration checkout, with an isolated
Hermes home/runtime and verified settings that preserve the custom branch and
commits. Never run it blindly against the running app's source or a guest. If
the available updater cannot preserve custom history, use its safe equivalent:
fetch the selected upstream revision, merge or rebase it onto our custom source,
then use the repository's supported PM/update-finish and build steps. Explain
this substitution. Do not invent flags, use forced resets, or run raw pip/uv
against a managed Hermes environment.

Resolve conflicts by intended behavior, not by accepting all of either side.
Inspect upstream history for changed APIs and deliberate behavior changes.
After integration, verify the resulting source still contains each required
custom behavior. A clean merge is not proof of compatibility.

Compare upstream changes against the feature inventory. Report each relevant
overlap as equivalent, partial, or incompatible, with upstream commit/release
links and the practical difference. Prefer upstream code when it meets the
same behavior and ownership contract. Remove a redundant local patch only
after proving equivalence with affected tests; retain adaptations needed for
our deployments. Ask before a meaningful behavior loss or data conversion.

## Verify and build

Run affected behavior tests and required repository gates. Hermes Python tests
use `scripts/run_tests.sh`; use the repository's managed test environment.
Check actual authentication, profile ownership, transcript persistence, and
HTTP/WebSocket contracts when touched. Exercise cross-version compatibility
between clients, controller, proxy, and guest during a staged rollout.

Build only changed components from committed source. Record separate Mac,
iPhone, Hermes backend, and Infra revisions when their source differs. Preserve
client data, Keychain, gateway identities, and existing signing arrangements.
Do not quit a client holding an unsent password or active session without an
appropriate handoff. Use protected credential input; never print secrets.

## Deploy the verified version

Read the current Infra instructions and Hermes deployment runbook. Use the
installed `infra:deploy-app` skill if available; otherwise follow the same
repository-owned build, publish, GitOps, and rollback procedures.

Verify the explicit Kubernetes context and API endpoint, namespace, workload,
Flux root, suspension state, and current image IDs. Inspect the exact proposed
manifest/configuration diff and compatible rollback. Reuse existing private
packages and protected publisher/pull credentials. Publish the tested images,
verify registry digests and architecture independently, and update committed
digest pins. Run Infra `make verify` for the exact revision being pushed.
Reconcile only the affected roots through their established deployment path.

Keep the main build source, guest source pin, source bundle, checksum, and driver
prerequisite consistent whenever backend code changes. Verify a bundle replay
from its prerequisite and the boot Secret size before publishing. A client-only
change does not require a backend rebuild or a new guest bundle.

Inventory existing managed bot VMs and their running Hermes versions. A new
controller image or bootstrap bundle does not update installed code on existing
VM disks. Use the established authenticated guest maintenance/update path to
apply the reviewed custom revision in place, preserving the Linux account,
workspace, credentials, transcript database, desktop, and disk identity. Check
for active jobs and sessions before restarting affected services. Update one
eligible idle guest first, verify it, then proceed sequentially with the rest.
Do not manufacture a new SSH exposure, grant pod exec, or recreate a VM to gain
an update path. If no supported path exists, report the concrete gap and leave
those guests explicitly pending; do not claim that the whole cluster is updated.

Verify rollout readiness plus private TLS, login, unauthorized denial, and the
affected real user flow on the controller and updated guests. Confirm state
survives required service restarts and that closing clients does not stop VMs.
Use existing non-destructive checks; do not create a paid/test VM or execute a
real deletion merely to test an update. Password entry remains with the user
where protected UI input requires it. Report any acceptance step that requires
human interaction instead of presenting fixture results as live proof.

On a failed release, stop advancing it. Restore a verified compatible image and
configuration when safe; data migrations require their actual restore plan.
Preserve registry receipts and all VM disks. Do not repeatedly retry unchanged
failures, expand permissions, or repeat green suites without new evidence.

## Handoff

Save a concise update record in the existing project delivery records. Include:

- Upstream before/after revisions and custom release commits.
- Conflicts resolved, upstream feature overlaps, patches retired or retained,
  and material concerns.
- Tests, client artifacts, published digests, observed deployment versions,
  and a per-guest updated/pending result.
- Live acceptance, human steps still needed, and the usable rollback.

Tell the user what changed and whether any of our features now exist upstream.
Distinguish source integration, build, publication, deployment, and live proof.
Do not report success for targets that remain unchanged or unverified.
