#!/usr/bin/env bash
# Live driver for the cross-home completion gate (branch fm/fm-captain-hold-cross-home).
#
# Replays the reported tebas-tech-proposal history against the real firstmate
# scripts in two disposable, marked lab homes (bin/fm-lab-home.sh):
#   main home  - runs the tebas-tech-proposal scout and first holds the
#                tebas-llm-provider captain call, attesting it with `complete`
#   mate home  - a firstmate checkout seeded as the tebas-pm secondmate by the
#                real bin/fm-home-seed.sh, which then receives the call through
#                the real bin/fm-backlog-handoff.sh
# then drives `verify` and `bin/fm-teardown.sh tebas-tech-proposal` in the main
# home the way the primary does, plus adversarial variants.
#
# Usage: drive-cross-home.sh <code-root> <scenario>
#   <code-root>  a firstmate checkout whose bin/ is under test (base or fix)
#   <scenario>   replay | complete-names-mate | answered | unregistered |
#                remote-route | bare-done | not-held | ghost | main-held
# Every lab directory is removed on exit.
set -u

CODE=$1
SCEN=$2
WT=/Users/programanding/.no-mistakes/worktrees/ae59da4a10c5/01M3TG6YXKJRV271AYT7KTXZ9X
TA_BIN="$(cat /tmp/fm-test-tasksaxi-dir-01M3)/node_modules/.bin"
LABROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
MAIN=$LABROOT/main
MATE=$LABROOT/treehouse/firstmate-lab/1/firstmate
SCOUT=tebas-tech-proposal
CALL=tebas-llm-provider
SCOUT_PANE=
cleanup() {
  # A refused teardown leaves the scout's lab tab open; close it so the next
  # scenario starts from an empty lab session.
  local tab
  if [ -n "${HERDR_LAB_SESSION:-}" ] && [ -f "$MAIN/state/$SCOUT.meta" ]; then
    tab=$(sed -n 's/^herdr_tab_id=//p' "$MAIN/state/$SCOUT.meta")
    [ -z "$tab" ] || "$WT/bin/fm-herdr-lab.sh" run "$HERDR_LAB_SESSION" tab close "$tab" >/dev/null 2>&1 || true
  fi
  rm -rf "$LABROOT"
}
trap cleanup EXIT

# The lab primary's environment: inherited fleet-path overrides and the test
# bypass are stripped so every path resolves inside the marked lab home, and
# NO_MISTAKES_GATE stays set so the gate refusal is live and the lab marker is
# what authorizes lifecycle calls.
fmenv() {
  local herdr=()
  # With HERDR_LAB_SESSION set the scout owns a real pane in that named
  # fm-lab-* session, and every Herdr resolution is pinned to it, never default.
  [ -z "${HERDR_LAB_SESSION:-}" ] || herdr=(HERDR_SESSION="$HERDR_LAB_SESSION")
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    -u HERDR_SESSION "${herdr[@]}" PATH="$TA_BIN:$PATH" "$@"
}

# step <home-label> <home> <command...>: one transcript entry, run from the
# code root like the primary does; lab paths are shortened for reading.
step() {
  local label=$1 home=$2 out rc=0
  shift 2
  printf '\n$ FM_HOME=<%s> %s\n' "$label" "$*"
  out=$(cd "$CODE" && fmenv FM_HOME="$home" "$@" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed "s#$LABROOT#<lab>#g"
  printf '[exit %s]\n' "$rc"
  return "$rc"
}

note() { printf '\n## %s\n' "$*"; }
show_file() {  # <label> <path>
  printf '\n--- %s ---\n' "$1"
  if [ -e "$2" ]; then sed "s#$LABROOT#<lab>#g" "$2"; else echo "(absent)"; fi
}

setup_homes() {
  note "setup: two marked lab homes; the mate home is a firstmate checkout"
  "$WT/bin/fm-lab-home.sh" create "$MAIN" >/dev/null || exit 90
  "$WT/bin/fm-lab-home.sh" create "$MATE" >/dev/null || exit 90
  cp "$WT/.tasks.toml" "$MAIN/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$MAIN/data/backlog.md"
  (cd "$WT" && git archive HEAD) | tar -x -C "$MATE" || exit 90
  step main "$MAIN" env FM_SECONDMATE_CHARTER='Own tebas product-management decisions.' \
    FM_SECONDMATE_SCOPE='tebas product management' \
    bin/fm-home-seed.sh tebas-pm "$MATE" --no-projects || exit 91
  show_file "main data/secondmates.md" "$MAIN/data/secondmates.md"
  show_file "mate .fm-secondmate-home" "$MATE/.fm-secondmate-home"

  note "setup: the finished tebas-tech-proposal scout in the main home"
  (cd "$MAIN" && fmenv tasks-axi add "$SCOUT" "Investigate the tebas tech proposal" \
    --kind scout --repo tebas --start >/dev/null) || exit 92
  cat > "$MAIN/state/$SCOUT.meta" <<EOF
window=firstmate:fm-$SCOUT
endpoint_task_id=$SCOUT
worktree=$MAIN/projects/.returned/$SCOUT
project=$MAIN/projects/tebas
harness=claude
kind=scout
tasktmp=$MAIN/state/tasktmp/$SCOUT
model=default
effort=default
spawn_gen=lab-$SCOUT
EOF
  if [ -n "${HERDR_LAB_SESSION:-}" ]; then
    endpoint=$(fmenv HERDR_SESSION="$HERDR_LAB_SESSION" bash "$(dirname "$0")/make-herdr-endpoint.sh" \
      "$CODE" "$MAIN" "$SCOUT") || exit 96
    grep -v '^window=' "$MAIN/state/$SCOUT.meta" > "$MAIN/state/$SCOUT.meta.tmp"
    printf '%s\n' "$endpoint" >> "$MAIN/state/$SCOUT.meta.tmp"
    mv "$MAIN/state/$SCOUT.meta.tmp" "$MAIN/state/$SCOUT.meta"
    SCOUT_PANE=$(sed -n 's/^herdr_pane_id=//p' "$MAIN/state/$SCOUT.meta")
    printf '\nscout endpoint: real Herdr pane %s in lab session %s\n' "$SCOUT_PANE" "$HERDR_LAB_SESSION"
  fi
  printf 'done: report complete\n' > "$MAIN/state/$SCOUT.status"
  mkdir -p "$MAIN/data/$SCOUT"
  printf '# Tebas tech proposal\n\nRecommendation is ready; the LLM provider choice is the captain'"'"'s.\n' \
    > "$MAIN/data/$SCOUT/report.md"
}

hold_and_attest() {  # <keys...>
  local key
  note "the scout's captain call is held in the main home and attested by complete"
  for key in "$@"; do
    step main "$MAIN" bin/fm-captain-hold.sh hold "$key" --title "Captain call $key" \
      --reason "captain must decide $key" --repo tebas --origin "$SCOUT" --until 2026-12-31 || exit 93
  done
  step main "$MAIN" bin/fm-captain-hold.sh complete "$SCOUT" "$@" || exit 94
  printf '\n--- main state/%s.meta attestation ---\n' "$SCOUT"
  grep -E '^(decisions_reviewed|decision_keys)=' "$MAIN/state/$SCOUT.meta"
}

hand_off() {
  note "the call is handed to the tebas-pm secondmate home"
  # The local receiver wake needs a running tebas-pm session; with none in the
  # lab the helper reports the wake failure after the durable move.
  step main "$MAIN" bin/fm-backlog-handoff.sh tebas-pm "$CALL" || true
  step mate "$MATE" bin/fm-captain-hold.sh open "$CALL" \
    || { echo "SETUP: mate does not hold the call"; exit 95; }
  step main "$MAIN" bin/fm-captain-hold.sh open "$CALL" --distinguish-absent || true
}

gate_and_teardown() {
  note "the primary cleans up the finished investigation"
  step main "$MAIN" bin/fm-captain-hold.sh verify "$SCOUT" || true
  step main "$MAIN" bin/fm-teardown.sh "$SCOUT" || true
  printf '\n--- after teardown ---\n'
  printf 'main scout record state/%s.meta: %s\n' "$SCOUT" "$([ -e "$MAIN/state/$SCOUT.meta" ] && echo present || echo removed)"
  if [ -n "${HERDR_LAB_SESSION:-}" ]; then
    printf 'scout Herdr pane %s: %s\n' "$SCOUT_PANE" \
      "$("$WT/bin/fm-herdr-lab.sh" run "$HERDR_LAB_SESSION" pane get "$SCOUT_PANE" 2>&1 \
        | jq -r 'if .error.code then "gone (" + .error.code + ")" else "still open (" + .result.pane.pane_id + ")" end')"
  fi
  printf 'main backlog mentions %s: %s\n' "$CALL" "$(grep -c "$CALL" "$MAIN/data/backlog.md" || true)"
  step main "$MAIN" bin/fm-tasks-axi.sh show "$SCOUT" || true
  step mate "$MATE" bin/fm-captain-hold.sh open "$CALL" || true
}

setup_homes
case "$SCEN" in
  replay)
    hold_and_attest "$CALL"
    hand_off
    gate_and_teardown
    ;;
  complete-names-mate)
    hold_and_attest "$CALL"
    hand_off
    note "complete is re-run after the handoff (a later review pass)"
    step main "$MAIN" bin/fm-captain-hold.sh complete "$SCOUT" "$CALL" || true
    grep -E '^(decisions_reviewed|decision_keys)=' "$MAIN/state/$SCOUT.meta"
    step main "$MAIN" bin/fm-captain-hold.sh verify "$SCOUT" || true
    ;;
  answered)
    hold_and_attest "$CALL"
    hand_off
    note "the captain answers the call in the tebas-pm home"
    printf 'Use the hosted provider; revisit cost in Q1.\n' > "$LABROOT/decision.txt"
    step mate "$MATE" bin/fm-captain-hold.sh answer "$CALL" --decision-file "$LABROOT/decision.txt" || true
    step mate "$MATE" bin/fm-captain-hold.sh open "$CALL" || true
    gate_and_teardown
    ;;
  unregistered)
    hold_and_attest "$CALL"
    hand_off
    note "ADVERSARIAL: tebas-pm is no longer registered in the main home"
    : > "$MAIN/data/secondmates.md"
    show_file "main data/secondmates.md" "$MAIN/data/secondmates.md"
    gate_and_teardown
    ;;
  remote-route)
    hold_and_attest "$CALL"
    hand_off
    note "ADVERSARIAL: the registry names the same home as a REMOTE route"
    printf -- '- tebas-pm - Own tebas product-management decisions. (host: build-box; root: /opt/firstmate; home: %s; scope: tebas product management; projects: ; added 2026-09-30)\n' \
      "$MATE" > "$MAIN/data/secondmates.md"
    show_file "main data/secondmates.md" "$MAIN/data/secondmates.md"
    gate_and_teardown
    ;;
  bare-done)
    hold_and_attest "$CALL"
    hand_off
    note "ADVERSARIAL: the mate closes the call with a bare done, no recorded captain answer"
    step mate "$MATE" bin/fm-tasks-axi.sh "done" "$CALL" || true
    gate_and_teardown
    ;;
  not-held)
    hold_and_attest "$CALL"
    hand_off
    note "ADVERSARIAL: the mate lifts the captain hold without an answer, leaving a plain open task"
    step mate "$MATE" bin/fm-tasks-axi.sh unhold "$CALL" || true
    step mate "$MATE" bin/fm-captain-hold.sh open "$CALL" || true
    gate_and_teardown
    ;;
  ghost)
    hold_and_attest "$CALL" tebas-db-choice
    hand_off
    note "ADVERSARIAL: the second attested call is deleted, so no home holds it"
    step main "$MAIN" bin/fm-tasks-axi.sh rm tebas-db-choice || true
    gate_and_teardown
    ;;
  main-held)
    hold_and_attest "$CALL"
    note "REGRESSION: the call stays in the main home (no handoff)"
    gate_and_teardown
    ;;
  *)
    echo "unknown scenario $SCEN" >&2
    exit 2
    ;;
esac
