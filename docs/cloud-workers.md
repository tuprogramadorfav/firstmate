# Cloud workers (claude-cloud)

`claude-cloud` runs a ship or scout worker in a Claude Code cloud session (claude.ai/code) instead of a local terminal, so the work draws on the subscription's cloud sessions while firstmate supervises it exactly like a local worker.
It is a worker runtime chosen per task, never a home-wide switch: a home that never selects it behaves exactly as before.

## Selecting it

Choose it the way any worker runtime is chosen: name `claude-cloud` as the harness of a dispatch profile in `config/crew-dispatch.json`, or pass `--harness claude-cloud` to `bin/fm-spawn.sh` for one task.
[Crew dispatch profiles](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns the profile schema.
`bin/fm-spawn.sh` is the only way a cloud worker starts; the primary session's delegation guard still refuses the harness's own cloud tools, because work started that way has no task record, supervision, or notifications.

A cloud worker runs ship and scout tasks only.
`bin/fm-spawn.sh` refuses, naming the reason and before any worktree, endpoint, task record, or session exists:

- a secondmate;
- a `local-only` ship, because a cloud session can deliver only by pushing its branch to GitHub and a local-only task publishes nothing;
- a backend other than tmux or Herdr, which alone give the bridge endpoint the agent-state proofs the control plane needs;
- a missing `claude` CLI or `jq`, a Claude Code login that is absent or not a claude.ai subscription login;
- a project whose origin is not on github.com, or whose origin the local `gh` login cannot push to.

A refusal never falls back to a local run.
A session the CLI does not report created stops the spawn the same way.

## Requirements

- The Claude Code CLI signed in with the claude.ai subscription account (`claude auth status` reports `authMethod: claude.ai`), on a plan with cloud sessions.
- The project on github.com, with the Claude GitHub App installed on the repository or GitHub connected through `/web-setup`, so the session can clone it and push branches. Without the App, `claude --cloud` uploads the local copy as a bundle instead; the session can still push only when the GitHub connection has push access.
- A cloud environment able to build and test the project. The CLI uses the environment chosen with `/remote-env` (the `remote.defaultEnvironmentId` user setting) or, failing that, its own default. A project's own setup belongs in that environment's setup script or in a SessionStart hook committed to the project's `.claude/settings.json` and gated on `CLAUDE_CODE_REMOTE=true` ([cloud environments](https://code.claude.com/docs/en/cloud-environments)).

### Choosing the environment per project (config/cloud-environment)

The optional, local, gitignored `config/cloud-environment` picks the environment for a project's cloud sessions without changing the operator's `/remote-env` choice.
Each non-comment line is `<project-name> <environment-id>`, and a `*` line is the fallback for every other project:

```text
# project   environment
tebas       env_01AbCd
*           ccpool_shared
```

An Anthropic-hosted `env_` id is applied as the `remote.defaultEnvironmentId` setting for that one `claude --cloud` invocation; a self-hosted `ccpool_` id is passed as `--environment`.
With no matching line the CLI's own choice applies.
A malformed line refuses the spawn naming the line, so a misconfigured environment never silently becomes the default.
[`fm_cloud_environment_args`](../bin/fm-cloud-lib.sh) owns the parsing.

## How it works

The spawn creates the cloud session with `claude --cloud`, from instructions that put a cloud runtime contract in front of the ordinary launch brief, and records the session in the task record as `cloud_session=` and `cloud_url=`.
The exact instructions sent are kept at `data/<id>/cloud-launch-brief.md`.
The task keeps an ordinary local endpoint, which runs [`bin/fm-cloud-bridge.sh`](../bin/fm-cloud-bridge.sh) instead of an agent, so peeking, notifications, busy state, stale detection, steering, the control plane, and recovery all work through their existing contracts.

The session cannot reach the operator's machine, so the task channels cross through Claude Code and GitHub:

| Channel | Path |
| --- | --- |
| Steering | Each record `bin/fm-send.sh` writes to the task inbox is sent once into the session with `claude -p <message> --cloud <session>`, which wakes an idle session. The record moves to `handled/` only when the worker acknowledges it, so the inbox's re-ring and escalation still measure the worker. |
| Status | The worker records each status line with the `fm-cloud` helper the instructions install, which pushes it to the return branch `fm-cloud/<home-tag>/<task-id>` on origin. The bridge appends each new line verbatim to `state/<id>.status`, so it wakes firstmate and classifies exactly as a local worker's line, and marks the task busy on `working:` or `resolved:` and idle on any other state. |
| Scout report | The worker publishes the report to the return branch; the bridge copies it to `data/<id>/report.md`. |
| Lifecycle | `bin/fm-control.sh` interrupt and exit keys reach the bridge, which sends the session an interrupt or exit request as a message. |

The bridge polls the return branch every 30 seconds (`FM_CLOUD_POLL_SECS`) and at once when the inbox doorbell rings.
A session that reports nothing within 15 minutes of launch (`FM_CLOUD_FIRST_STATUS_SECS`) gets one `blocked:` line, because repository access or startup most likely failed.
[`bin/fm-cloud-lib.sh`](../bin/fm-cloud-lib.sh) owns the branch name, the instructions, session creation, and sending; [`bin/fm-cloud-worker.sh`](../bin/fm-cloud-worker.sh) is the cloud-side helper.

## Delivery

A cloud ship implements, commits, and pushes its task branch and reports `done:` naming the pushed head; it never runs the pipeline, opens a pull request, or merges.
Before relaying that `done:`, the bridge fetches the branch and fast-forwards the task's local copy onto it, so the delivery path runs locally on exactly the pushed head; when the branch is missing or the local copy has diverged, it relays a `blocked:` line naming the reason instead.
Firstmate then hands the task to a local worker with `bin/fm-control.sh <id> relaunch --harness <local harness> --note <...>`, which runs the selected delivery path unchanged: the full no-mistakes pipeline and its PR for `no-mistakes`, the push and PR for `direct-PR`.
Landing, merge authority, and cleanup keep their existing guards (`bin/fm-pr-merge.sh`, `bin/fm-teardown.sh`).
A cloud scout's deliverable is the report copied into `data/<id>/report.md`; it never commits or pushes to the project.

## Lifecycle

- **Interrupt and exit** are messages the worker reads at its next turn boundary; the CLI cannot cancel a running cloud turn.
  `exit` sends the exit request and stops the bridge, which the control plane observes as the agent stopping.
- **Relaunch** creates a new session for the same task and branch; a previous session that never received an exit request is sent one first.
  Relaunching onto a local harness is how a ship moves to local delivery.
- **Recovery after a firstmate restart** needs nothing special: the bridge keeps running in its endpoint, and a restarted bridge resumes from `state/<id>.cloud-sync` without relaying or sending anything twice.
  A dead bridge is handled like any dead worker endpoint.
- **Cleanup** tells a session that was never sent an exit request that the task is closed, then deletes the return branch; either failure refuses cleanup before anything irreversible, and a re-run converges.

## Limits

- The session sees only GitHub: never the operator's files, local databases or their data, local containers, firstmate's home, or local credentials. Its own VM has its own toolchains, Docker, PostgreSQL, and Redis.
- The CLI cannot attach to a session, read its conversation, cancel a running turn, or archive it. Finished sessions stay listed at claude.ai/code until the captain archives them there.
- `claude --cloud` has no verified model or effort selection, so a profile's model and effort are recorded in the task record but not applied; the session uses the account's cloud default.
- Cloud sessions count toward the plan's usage limits like every other Claude usage.
- An idle session's VM is reclaimed after a period of inactivity, losing any background work; opening the session URL reopens it with its conversation. A steering message reached and woke a session idle for 20 minutes, but whether a message alone reopens a reclaimed VM is not verified, so a cloud worker that stops reporting after a long wait may need its session opened.

[Verification record](verification/claude-cloud.md) holds the live evidence for these behaviors.
