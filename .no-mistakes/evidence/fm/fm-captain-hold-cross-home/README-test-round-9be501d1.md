# Live validation at 9be501d1 - completion gate accepts a call held in a registered secondmate home

Driver: `drive-cross-home-teardown.sh <firstmate-tree> <scratch-parent>` (this directory).
It drives the real `bin/fm-lab-home.sh`, `bin/fm-home-seed.sh`, `bin/fm-captain-hold.sh` (hold, complete, verify, open, answer), `bin/fm-backlog-handoff.sh`, and `bin/fm-teardown.sh` against disposable homes.
The main home is a marked lab home, so the gate guard permits teardown without any bypass or `FM_*_OVERRIDE`.
The `tebas-pm` secondmate home is seeded by the real seeder, which writes its `.fm-secondmate-home` marker and the `data/secondmates.md` row.
`tasks-axi` 0.2.6 came from a throwaway npm prefix.

The replayed operator history: scout `tebas-tech-proposal` finishes, its call `tebas-llm-provider` is held in the main home until 2026-12-31 and attested by `complete`, and the call is then handed to `tebas-pm` by the real handoff.
`FM_HOME=<tebas-pm> fm-captain-hold.sh open tebas-llm-provider` exits 0, and the main home runs `verify` and `fm-teardown.sh tebas-tech-proposal`.
The handoff's own exit 1 is only its receiver wake: the lab has no live `tebas-pm` session to wake, and the move itself is reported durable.

| Transcript | Tree | Scout endpoint | What it shows |
| --- | --- | --- | --- |
| `base-windowless-transcript.log` | base 8690c411 | none (windowless record) | Bug reproduced: after the handoff, `verify`, `complete`, and `fm-teardown.sh` refuse with "no captain-held task tebas-llm-provider ... in this home's configured backlog", and the scout is kept |
| `target-herdr-transcript.log` | target 9be501d1 | real pane in named Herdr lab `fm-lab-capthold-*` | `verified:`; `teardown tebas-tech-proposal complete`; pane then reads `pane_not_found`; scout row closed with its report; call still held only in `tebas-pm` |
| `target-windowless-transcript.log` | target 9be501d1 | none (windowless record) | Same full cleanup without a backend endpoint |
| `target-tmux-record-transcript.log` | target 9be501d1 | tmux window record, no tmux binary on this host | Gate passes; teardown then stops only at closing the tmux window, because tmux is not installed |

The adversarial sections are identical in every target transcript, and each one refuses `verify`, naming the entry.
They cover: marker removed (teardown is also refused and the scout kept), marker naming `other-mate`, marker as a symlink to a file naming `tebas-pm`, the registered path replaced by an unseeded home that holds the same id, the registry row removed, the row turned into a remote route, an attested ghost call, and a secondmate task closed by a bare `tasks-axi done` (teardown also refused).
`complete` prints `[held in a registered secondmate home: tebas-llm-provider=tebas-pm]`, and once `tebas-pm` answers the call, `verify` still passes.
