# Claude cloud worker verification

Live evidence for the `claude-cloud` worker runtime ([`cloud-workers.md`](../cloud-workers.md)).
Recorded 2026-10-27 on macOS with Claude Code 2.1.312, logged in with a claude.ai subscription account, against a public GitHub fork with the Claude GitHub App connection the account already had.

## CLI surface

| Probe | Observed |
| --- | --- |
| `claude --cloud "<prompt>"` under a pseudo-terminal | Prints `Created cloud session: <title>`, `View: https://claude.ai/code/session_<id>?from=cli&m=0`, and `Resume with: claude --teleport session_<id>`, then exits; the session runs on. |
| `claude --cloud "<prompt>"` from a checkout whose branch is not on GitHub | Adds `Branch <name> is not on GitHub, so the cloud session starts from its own commit, which origin/main has (<sha>).` and starts from that commit. |
| `claude --cloud "<prompt>"` from a folder Claude Code was never told to trust | Stops on the workspace-trust dialog (`Quick safety check: Is this a project you created or one you trust?`) and never creates the session; `bin/fm-spawn.sh` therefore pre-registers trust for the task worktree. |
| `claude --cloud <session-id>` (interactive attach) | `Error: Attaching to an existing cloud session is not enabled for your account.` |
| `claude -p "<message>" --cloud <session-id> --output-format json` | `{"ok":true,"session_id":"session_<id>","url":"https://claude.ai/code/session_<id>?from=cli&m=0"}`; a session idle for 20 minutes received the message and acted on it 11 seconds later. |
| `claude agents --json --all` | Lists local background and interactive sessions only; cloud sessions do not appear. |
| `claude --help` | No subcommand stops, reads, or archives a cloud session. |

## Inside the cloud session

A probe session reported, by pushing its own command transcript:

- It started on a branch named `claude/<slug>`, cloned from the fork at the default branch's head.
- `git push` to an arbitrary branch name (`fm/...`, `fm-cloud/...`) and to a ref built from a commit created in a separate temporary repository both succeeded.
- `gh auth status` failed (`The token in GH_TOKEN is invalid`), so a cloud worker cannot open pull requests itself.
- `CLAUDE_CODE_REMOTE`, `CLAUDE_CODE_REMOTE_SESSION_ID`, and the git proxy variables are set; the VM is Linux x86_64.
- A single background shell loop kept running across its turn and woke it when it finished.

## End-to-end run

An isolated temporary home dispatched a ship and a scout against a scratch clone of the fork with the real `bin/fm-spawn.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`, `bin/fm-captain-hold.sh`, and `bin/fm-teardown.sh`.
The terminal multiplexer was the suite's spawn-world tmux fake, and each bridge ran from the exact staged launch command inside an `expect` pseudo-terminal, because the machine had no tmux and the run could not drive Herdr lifecycle.

| Step | Observed |
| --- | --- |
| Ship spawn (`--mode direct-PR --harness claude-cloud`) | Created the session and recorded `cloud_session=` and `cloud_url=`; the bridge rendered its header and the spawn completed. |
| First report | `working [at=…]: cloud session started` then `done [at=…]: pushed fm/cloud-e2e-ship at f2eb4573…` were appended to the task's status file within a poll, and the busy record moved to `idle cloud-bridge`. |
| Local copy | The ship's local copy was on `fm/cloud-e2e-ship` at `f2eb4573`, tracking `origin/fm/cloud-e2e-ship`, before the `done:` line was relayed. |
| Steering | `bin/fm-send.sh cloud-e2e-ship "<follow-up>"` wrote `inbox/001.msg`; the bridge sent it into the session once; the worker committed and pushed `46ab5afb`, acknowledged the record (moved to `handled/`), and reported a second `done:`, after which the local copy had fast-forwarded to `46ab5afb`. |
| Interrupt (Escape into the bridge) | The worker reported `paused [at=…]: interrupted on firstmate request; …` about 30 seconds later. |
| Exit (Ctrl-U, Ctrl-C into the bridge) | The bridge sent the exit request, recorded `ended_session=`, and ended; the worker pushed `paused [at=…]: exiting on firstmate request`. |
| Scout | `done` arrived within a minute and the report published with `fm-cloud report` was copied byte for byte to `data/cloud-e2e-scout/report.md`; `bin/fm-crew-state.sh` read `state: done · source: status-log`. |
| Cleanup | `bin/fm-teardown.sh` completed for both; the scout's session (never sent an exit) was told the task is closed, the ship's (already exited) was not, and both return branches were deleted from origin. |

## Herdr lifecycle control

Recorded 2026-10-27 with Herdr 0.9.1 in an isolated `fm-lab-` session. The real bridge ran in a task pane, and a fake Claude Code CLI stood in for the cloud service.
Herdr has no detection entry for the bridge, and before the bridge reported itself `herdr agent get` answered `agent_not_found` for its pane, so `fm_backend_agent_state` read a running bridge as `dead`:

- `bin/fm-control.sh <id> interrupt` refused.
- `exit` printed `already-stopped` while the bridge kept running, and no exit request was sent.
- `relaunch --harness claude` typed the local launch lines into the still-running bridge.

With the bridge reporting its pane (`pane report-agent --source firstmate:cloud-bridge --agent claude-cloud`, `release-agent` on exit), the same pane gave these results:

| Step | Observed |
| --- | --- |
| Running bridge | `fm_backend_agent_state herdr` read `alive`. |
| `fm-control interrupt` | `interrupt-delivered … verified=agent-alive`; the session was sent the interrupt request. |
| `fm-control exit` | The bridge sent the exit request and ended; `agent get` answered `agent_not_found` and the pane read `dead`. |
| `fm-control relaunch --harness claude --note …` | The bridge was stopped, and the superseded session was sent an exit request. A stand-in local claude started in the same pane and read `alive`, and the record named `harness=claude`. |

[`tests/fm-cloud-bridge-herdr-e2e.test.sh`](../../tests/fm-cloud-bridge-herdr-e2e.test.sh) is that regression; rerun it after every Herdr upgrade.

Not exercised live: the control plane's verbs on a real tmux pane, the `config/cloud-environment` selectors, the private-origin refusal (the end-to-end run above used a public fork and predates it), and a message reaching a session whose VM had been reclaimed.
The portable regressions are [`tests/fm-cloud-bridge.test.sh`](../../tests/fm-cloud-bridge.test.sh) and [`tests/fm-cloud-spawn.test.sh`](../../tests/fm-cloud-spawn.test.sh).
