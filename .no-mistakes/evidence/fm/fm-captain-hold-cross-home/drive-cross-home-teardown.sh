#!/usr/bin/env bash
# Live driver for the cross-home captain-call completion gate.
# Usage: drive-cross-home-teardown.sh <firstmate-tree> <scratch-parent>
#
# Builds disposable homes under <scratch-parent> and drives the real firstmate
# entrypoints from <firstmate-tree>/bin against them, the way the operator did:
#   - main home = a marked lab home (bin/fm-lab-home.sh create) so the gate
#     guard permits fm-teardown.sh without any bypass or FM_*_OVERRIDE;
#   - the secondmate home is seeded by the real bin/fm-home-seed.sh, which
#     writes its .fm-secondmate-home marker and the data/secondmates.md row;
#   - the scout's captain call is held with fm-captain-hold.sh hold, attested
#     with fm-captain-hold.sh complete, and handed off with the real
#     bin/fm-backlog-handoff.sh;
#   - teardown is the real bin/fm-teardown.sh <scout>.
# Every command and its exit status is echoed so the transcript is the evidence.
set -u
TREE=$1
P=$2
BIN="$TREE/bin"
M="$P/main"
MATE="$P/tebas-pm-home"
SCOUT=tebas-tech-proposal
CALL=tebas-llm-provider

say() { printf '\n### %s\n' "$*"; }
run() {  # echo the command, run it, print its status
  printf '$ %s\n' "$*"
  "$@"
  local rc=$?
  printf '[exit %s]\n' "$rc"
  return "$rc"
}
in_main() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$M" "$@"; }
in_mate() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$MATE" "$@"; }
tasks_main() { (cd "$M" && tasks-axi "$@"); }
tasks_mate() { (cd "$MATE" && tasks-axi "$@"); }

stage_scout() {  # (re)write the scout record the way fm-spawn.sh does, plus its finished report
  tasks_main show "$SCOUT" >/dev/null 2>&1 \
    || tasks_main add "$SCOUT" "Investigate the Tebas tech proposal" --kind scout --repo tebas --start >/dev/null
  # SCOUT_SHAPE=windowless records a scout whose endpoint is already gone (no
  # window= and no spawn_gen=), a shape fm-teardown.sh accepts natively;
  # SCOUT_SHAPE=herdr gives the scout a real pane in the named fm-lab-* Herdr
  # session HERDR_LAB_SESSION through make-herdr-endpoint.sh (fm-spawn.sh's own
  # herdr adapter calls); the default records the tmux window fm-spawn.sh writes.
  local endpoint=
  if [ "${SCOUT_SHAPE:-tmux}" = herdr ]; then
    endpoint=$(HERDR_SESSION="$HERDR_LAB_SESSION" bash "$(dirname "$0")/make-herdr-endpoint.sh" "$TREE" "$M" "$SCOUT") \
      || { echo "could not create the scout's Herdr lab pane"; exit 1; }
    echo "--- scout endpoint (real Herdr lab pane):"; printf '%s\n' "$endpoint"
    SCOUT_PANE=$(printf '%s\n' "$endpoint" | sed -n 's/^herdr_pane_id=//p')
    echo "--- scout pane $SCOUT_PANE before teardown:"
    "$BIN/fm-herdr-lab.sh" run "$HERDR_LAB_SESSION" pane get "$SCOUT_PANE" 2>&1 | jq -c '.result.pane | {pane_id, tab_id, workspace_id}' 2>&1
  fi
  {
    case "${SCOUT_SHAPE:-tmux}" in
      windowless) ;;
      herdr) printf '%s\n' "$endpoint" | grep '^window=' ;;
      *) echo "window=fm-lab:fm-$SCOUT" ;;
    esac
    echo "endpoint_task_id=$SCOUT"
    echo "worktree=$P/worktrees/$SCOUT"
    echo "project=$M/projects/tebas"
    echo "harness=claude"
    echo "kind=scout"
    echo "tasktmp=$P/tasktmp/$SCOUT"
    echo "model=default"
    echo "effort=default"
    [ "${SCOUT_SHAPE:-tmux}" = windowless ] || echo "spawn_gen=s$(date +%s).$$.lab$RANDOM"
    [ "${SCOUT_SHAPE:-tmux}" != herdr ] || printf '%s\n' "$endpoint" | grep -v '^window='
  } > "$M/state/$SCOUT.meta"
  printf 'done: report complete\n' > "$M/state/$SCOUT.status"
  mkdir -p "$M/data/$SCOUT"
  printf '# Tebas tech proposal\n\nThe proposal is ready; the LLM provider is a captain call.\n' > "$M/data/$SCOUT/report.md"
}

say "Build the disposable main lab home and seed the tebas-pm secondmate home"
run "$BIN/fm-lab-home.sh" create "$M" >/dev/null
cp "$TREE/.tasks.toml" "$M/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$M/data/backlog.md"
mkdir -p "$M/projects/tebas"
run in_main env FM_SECONDMATE_CHARTER='Tebas product-management decisions.' \
  "$BIN/fm-home-seed.sh" tebas-pm "$MATE" --no-projects
MATE=$(cd "$MATE" && pwd -P)
echo "--- main data/secondmates.md"; cat "$M/data/secondmates.md"
echo "--- mate .fm-secondmate-home: $(cat "$MATE/.fm-secondmate-home")"

say "Scout finishes; its captain call is held in the main home and attested by complete"
stage_scout
run in_main "$BIN/fm-captain-hold.sh" hold "$CALL" --title "Choose the Tebas LLM provider" \
  --reason "captain must pick the LLM provider" --repo tebas --origin "$SCOUT" --until 2026-12-31
run in_main "$BIN/fm-captain-hold.sh" complete "$SCOUT" "$CALL"
echo "--- scout meta attestation:"; grep -E '^(decisions_reviewed|decision_keys)=' "$M/state/$SCOUT.meta"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"

say "Captain says: close the board - hand the call to tebas-pm through the real handoff"
run in_main "$BIN/fm-backlog-handoff.sh" tebas-pm "$CALL"
echo "--- main backlog still names $CALL? $(grep -c "$CALL" "$M/data/backlog.md") line(s)"
echo "--- mate backlog row:"; grep -n "$CALL" "$MATE/data/backlog.md"
run in_mate "$BIN/fm-captain-hold.sh" open "$CALL"

say "Main-home gate after the handoff (the reported refusal)"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"

say "ADVERSARIAL: registered home with its .fm-secondmate-home marker removed"
mv "$MATE/.fm-secondmate-home" "$P/marker.saved"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"
run in_main "$BIN/fm-teardown.sh" "$SCOUT"
echo "--- scout meta still present after refused teardown? $([ -f "$M/state/$SCOUT.meta" ] && echo yes || echo no)"

say "ADVERSARIAL: marker names another secondmate id"
printf 'other-mate\n' > "$MATE/.fm-secondmate-home"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"

say "ADVERSARIAL: marker is a symlink to a file naming the right id"
rm -f "$MATE/.fm-secondmate-home"
printf 'tebas-pm\n' > "$P/forged-marker"
ln -s "$P/forged-marker" "$MATE/.fm-secondmate-home"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"
rm -f "$MATE/.fm-secondmate-home"
mv "$P/marker.saved" "$MATE/.fm-secondmate-home"

say "ADVERSARIAL: registered path replaced by a different home that holds the same id"
mv "$MATE" "$P/tebas-pm-home.real"
mkdir -p "$MATE/data" "$MATE/state" "$MATE/config"
cp "$TREE/.tasks.toml" "$MATE/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$MATE/data/backlog.md"
run in_mate "$BIN/fm-captain-hold.sh" hold "$CALL" --title "Impostor copy" \
  --reason "impostor hold" --repo tebas --until 2026-12-31 >/dev/null
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"
rm -rf "$MATE"
mv "$P/tebas-pm-home.real" "$MATE"

say "ADVERSARIAL: the home is not registered (row removed from data/secondmates.md)"
cp "$M/data/secondmates.md" "$P/secondmates.saved"
grep -v '^- tebas-pm ' "$P/secondmates.saved" > "$M/data/secondmates.md"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"

say "ADVERSARIAL: the registry row is a remote route (host: set)"
sed 's/(home: /(host: somewhere; root: \/opt\/fm; home: /' "$P/secondmates.saved" > "$M/data/secondmates.md"
cat "$M/data/secondmates.md"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"
cp "$P/secondmates.saved" "$M/data/secondmates.md"

say "ADVERSARIAL: the attested inventory names a call held nowhere"
sed -i '' "s/^decision_keys=.*/decision_keys=$CALL,tebas-ghost-call/" "$M/state/$SCOUT.meta"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"
sed -i '' "s/^decision_keys=.*/decision_keys=$CALL/" "$M/state/$SCOUT.meta"

say "complete in the main home names the secondmate carrying the call"
run in_main "$BIN/fm-captain-hold.sh" complete "$SCOUT" "$CALL"

say "Restored genuine registered home: verify and the operator's teardown"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"
run in_main "$BIN/fm-teardown.sh" "$SCOUT"
echo "--- scout meta after teardown: $([ -f "$M/state/$SCOUT.meta" ] && echo present || echo removed)"
if [ "${SCOUT_SHAPE:-tmux}" = herdr ]; then
  echo "--- scout Herdr pane $SCOUT_PANE after teardown (lab session $HERDR_LAB_SESSION):"
  "$BIN/fm-herdr-lab.sh" run "$HERDR_LAB_SESSION" pane get "$SCOUT_PANE" 2>&1 | head -5
fi
echo "--- scout report dir after teardown: $([ -d "$M/data/$SCOUT" ] && echo present || echo removed)"
echo "--- main backlog row for the scout:"; grep -n "$SCOUT" "$M/data/backlog.md" "$M/data/done-archive.md" 2>/dev/null
echo "--- main backlog names $CALL? $(grep -c "$CALL" "$M/data/backlog.md") line(s)"
run in_mate "$BIN/fm-captain-hold.sh" open "$CALL"

say "Answered in the secondmate home: a fresh scout attesting it still passes verify"
printf 'Use the Tebas default provider.\n' > "$P/decision.txt"
run in_mate "$BIN/fm-captain-hold.sh" answer "$CALL" --decision-file "$P/decision.txt"
stage_scout
printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$CALL" >> "$M/state/$SCOUT.meta"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"

say "ADVERSARIAL: a secondmate task closed with a bare tasks-axi done (no recorded answer)"
tasks_mate add tebas-plain-work "Finish plain work" --repo tebas >/dev/null
tasks_mate done tebas-plain-work >/dev/null
sed -i '' "s/^decision_keys=.*/decision_keys=tebas-plain-work/" "$M/state/$SCOUT.meta"
run in_main "$BIN/fm-captain-hold.sh" verify "$SCOUT"
run in_main "$BIN/fm-teardown.sh" "$SCOUT"
echo "--- scout meta still present after refused teardown? $([ -f "$M/state/$SCOUT.meta" ] && echo yes || echo no)"
exit 0
