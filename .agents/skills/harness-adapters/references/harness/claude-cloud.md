# Claude cloud (claude-cloud)

The adapter name is `claude-cloud`: a Claude Code cloud session driven through the installed `claude` CLI, with a local bridge as the task's endpoint.
The router owns the crewmate/scout-only boundary; a secondmate or primary is refused.
[`docs/cloud-workers.md`](../../../../../docs/cloud-workers.md) owns the operator contract and [verification evidence](../../../../../docs/verification/claude-cloud.md) the live facts.

## Operating facts

| Fact | Value |
|---|---|
| Endpoint program | `../../../bin/fm-cloud-bridge.sh`, re-executed under the anchored process name `fm-cloud-bridge`; it is the endpoint's agent for liveness and exit proofs. On Herdr it registers its pane as agent `claude-cloud` from source `firstmate:cloud-bridge` (idle at start, working or idle with each relayed line) and releases the registration on exit, because Herdr reads liveness only from its agent registry. |
| Busy state | Written by the bridge (source `cloud-bridge`) from relayed status lines: `working:` and `resolved:` open a turn, every other state closes it and touches `state/<id>.turn-ended`. |
| Interrupt | One Escape; the bridge sends the session an interrupt request it honors at its next turn boundary, so cancellation stays unconfirmed. |
| Exit command | `C-c`; the bridge sends the session an exit request and ends, so the endpoint reads agent-free. |
| Skill invocation | None: nothing typed into the bridge reaches the session. Send instructions as ordinary steering through `../../../bin/fm-send.sh`. |
| Resume | Not a verb; `relaunch` creates a new session for the same task and branch and sends an un-exited previous session an exit request. |
| Model and effort | Recorded but not applied; `claude --cloud` has no verified selection. |
| Trust dialogs | None locally; the session's own permission mode is the account's cloud default. |
| Backends | tmux and Herdr only. |

## Delivery handoff

A cloud ship cannot run the delivery pipeline: it pushes its task branch and reports `done:`, and the bridge relays that line only after the local copy is fast-forwarded onto the pushed head.
On that `done:`, run `../../../bin/fm-control.sh <id> relaunch --harness <local harness> --note <note>` and continue the task's ordinary delivery path on the local worker: trigger validation for `no-mistakes`, or the push and PR for `direct-PR`.
The note tells the local worker that the implementation is already committed on its task branch at the named head, the branch exists so its setup branch step is already satisfied, and its job is the delivery path alone.
A `local-only` ship is refused at spawn.

A cloud scout's report reaches `data/<id>/report.md` through the bridge; scout completion is unchanged.

## Steering and status

Every steer rides the task inbox; the bridge sends each record into the session once and moves it to `handled/` only on the worker's acknowledgement.
Status lines arrive through the return branch, normally within one poll (30 seconds) of the worker recording them.
A session silent for 15 minutes after launch is reported `blocked:` once; read the session URL from the task record (`cloud_url=`) and open it to inspect what the CLI cannot read.
