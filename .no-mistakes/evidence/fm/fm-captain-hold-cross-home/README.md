# Live validation - captain call held in a registered secondmate home

All runs drive the real firstmate scripts (`bin/fm-captain-hold.sh`, `bin/fm-teardown.sh`, `bin/fm-home-seed.sh`, `bin/fm-backlog-handoff.sh`) against two disposable marked lab homes from `bin/fm-lab-home.sh`, with `tasks-axi` 0.2.6 installed into a throwaway npm prefix.
The scout's endpoint is a real Herdr pane in a named `fm-lab-*` session provisioned and torn down through `bin/fm-herdr-lab.sh`; the default session was never touched (tripwire check passed at teardown).

Replayed history (the reported one): the `tebas-tech-proposal` scout's call `tebas-llm-provider` is held in the main home until 2026-12-31, attested by `complete`, then handed to the `tebas-pm` secondmate (seeded by the real seeder) with the real handoff helper.
`FM_HOME=<mate> bin/fm-captain-hold.sh open tebas-llm-provider` exits 0, then the primary runs `verify` and `bin/fm-teardown.sh tebas-tech-proposal` in the main home.

| Log | Code | Result |
| --- | --- | --- |
| `01-base-fd325b1-replay-teardown-refused.log` | base | Bug reproduced: `verify` and teardown refuse with "no captain-held task tebas-llm-provider ... in this home's configured backlog"; scout record and pane kept |
| `02-fix-replay-teardown-completes.log` | fix | `verified:`; `teardown tebas-tech-proposal complete`; scout closed, record removed, Herdr pane `pane_not_found`; call still held in tebas-pm and never copied into the main backlog |
| `03-fix-complete-names-mate.log` | fix | Re-run `complete` prints `[held in a registered secondmate home: tebas-llm-provider=tebas-pm]` |
| `04-fix-answered.log` | fix | Call answered in tebas-pm; main `verify` and full teardown pass |
| `05-fix-unregistered.log` | fix | Registry row removed: refused, scout kept |
| `06-fix-remote-route.log` | fix | Same home registered as a remote route: refused, scout kept |
| `07-fix-bare-done.log` | fix | Mate closes with bare `done` (no recorded answer): refused, scout kept |
| `08-fix-not-held.log` | fix | Mate lifts the hold without an answer: refused, scout kept |
| `09-fix-ghost.log` | fix | Second attested call deleted everywhere: refused naming `tebas-db-choice` |
| `10-fix-main-held.log` | fix | Regression: call kept in the main home still verifies and tears down |
| `11-base-fd325b1-new-regression-test-fails.log` | base | The branch's new suite case fails on base (it passes on the fix) |

Reproduce: `drive-cross-home.sh <code-root> <scenario>` with `HERDR_LAB_SESSION` set to a provisioned `fm-lab-*` session; it reads the tasks-axi prefix from `/tmp/fm-test-tasksaxi-dir-01M3`.
`make-herdr-endpoint.sh` creates the scout pane through the same adapter functions `bin/fm-spawn.sh` uses.
