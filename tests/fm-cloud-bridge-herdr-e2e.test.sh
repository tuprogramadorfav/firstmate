#!/usr/bin/env bash
# tests/fm-cloud-bridge-herdr-e2e.test.sh - real-herdr regression for the
# claude-cloud bridge as a task endpoint the control plane can drive.
#
# Herdr counts a pane as hosting an agent only through its own agent registry,
# and has no detection entry for the bridge, so a bridge that never reported
# itself read `dead` while it ran: fm-control interrupt refused, exit printed
# already-stopped without sending the cloud session an exit request, and a
# relaunch to a local harness typed its launch lines into the still-running
# bridge. This runs the real bridge (bin/fm-cloud-bridge.sh, launched the way
# bin/fm-spawn.sh launches it) in a real lab pane, with a fake Claude Code CLI
# standing in for the cloud service, and drives the real bin/fm-control.sh
# interrupt, exit, and relaunch --harness claude through it.
#
# The replacement local claude is a stand-in that reports itself to Herdr and
# then runs as an agent-named process, so no real harness is launched, and
# CLAUDE_CONFIG_DIR points the launch's trust registration at the scratch tree.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh). Skips cleanly when herdr or jq is missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

STANDIN_DIR=$(fm_test_tmproot fm-cloud-herdr-standin) || fail "could not create the stand-in directory"
STANDIN_BIN=$(fm_agent_standin "$STANDIN_DIR") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}

SESSION="fm-lab-cloud-bridge-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
LAB_PREPARED=0
cleanup_all() {
  local status=$? cleanup_status=0
  trap - EXIT
  if [ "$LAB_PREPARED" = 1 ]; then
    herdr_safe_stop_and_delete "$SESSION" || {
      echo "not ok - could not tear down Herdr lab session: $SESSION" >&2
      cleanup_status=1
    }
  fi
  if [ -n "$SCRATCH" ]; then
    chmod -R u+w "$SCRATCH" 2>/dev/null || true
    rm -rf "$SCRATCH" || {
      echo "not ok - could not remove the scratch tree: $SCRATCH" >&2
      cleanup_status=1
    }
  fi
  fm_test_cleanup
  [ "$cleanup_status" = 0 ] || status=1
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
LAB_PREPARED=1

fm_git_identity
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-cloud-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
ID=cherdr
HOME_DIR="$SCRATCH/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
CONFIG="$HOME_DIR/config"
mkdir -p "$STATE" "$DATA/$ID" "$CONFIG" "$SCRATCH/claude-config"
cat > "$DATA/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise cloud lifecycle control.

## Firstmate spec
Hand the cloud ship to a local worker.
EOF

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
fm_git_init_commit "$PROJ"
git clone -q --bare "$PROJ" "$SCRATCH/origin.git"
git -C "$PROJ" remote add origin "file://$SCRATCH/origin.git"
git -C "$PROJ" worktree add --quiet -b "fm/$ID" "$WT"

# The fake Claude Code CLI: every message queued into the cloud session is
# appended to sent.log framed by its session id.
SENT="$SCRATCH/sent.log"
: > "$SENT"
cat > "$SCRATCH/cloud-claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -p ] && [ "\${2:-}" = --cloud ]; then
  { printf '>>> %s\n' "\$3"; cat; printf '\n<<<\n'; } >> '$SENT'
  printf '{"ok":true,"session_id":"%s","url":"https://claude.ai/code/%s"}\n' "\$3" "\$3"
  exit 0
fi
exit 1
SH
chmod +x "$SCRATCH/cloud-claude"

# The replacement local claude: it registers in Herdr as the real one's
# integration would, then runs as an agent-named foreground process.
AGENT_BIN="$SCRATCH/agentbin"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$AGENT_BIN" "$FAKEBIN"
ln -s "$STANDIN_BIN" "$AGENT_BIN/claude"
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
: > '$SCRATCH/local-claude-launched'
herdr pane report-agent "\$HERDR_PANE_ID" --source fm-cloud-herdr-test --agent claude --state idle >/dev/null 2>&1
exec '$AGENT_BIN/claude' 900
SH
chmod +x "$FAKEBIN/claude"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
T="$SESSION:$PANE_ID"

CLOUD_SESSION=session_cherdr
BUSY_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID")
fm_write_meta "$STATE/$ID.meta" \
  "window=$T" "endpoint_task_id=$ID" "worktree=$WT" "project=$PROJ" \
  "harness=claude-cloud" "kind=ship" "mode=no-mistakes" "yolo=off" "branch=fm/$ID" \
  "model=default" "effort=default" "busy_gen=$BUSY_GEN" "spawn_gen=s1.$ID" \
  "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WORKSPACE_ID" \
  "herdr_tab_id=$TAB_ID" "herdr_pane_id=$PANE_ID" \
  "cloud_session=$CLOUD_SESSION" "cloud_url=https://claude.ai/code/$CLOUD_SESSION"
: > "$STATE/$ID.status"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CLOUD_CLAUDE="$SCRATCH/cloud-claude" CLAUDE_CONFIG_DIR="$SCRATCH/claude-config" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

wait_until() {  # <tries> <command...>
  local tries=$1 i=0
  shift
  while [ "$i" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}
screen() { fm_backend_herdr_visible_capture "$T" 2>/dev/null; }
bridge_drawn() { screen | grep -qF "fm-cloud-bridge  task $ID "; }
agent_state_is() { [ "$(fm_backend_agent_state herdr "$T")" = "$1" ]; }
sent_has() { grep -qF -- "$1" "$SENT"; }

# Start the bridge in the pane exactly as bin/fm-spawn.sh's claude-cloud
# launch does, with the fake cloud CLI and the stand-in local claude on PATH.
printf -v Q_FAKEBIN '%q' "$FAKEBIN"
printf -v Q_CLOUD '%q' "$SCRATCH/cloud-claude"
printf -v LAUNCH 'FM_HOME=%q FM_ROOT=%q FM_CLOUD_POLL_SECS=1 bash %q %q %q %q %q' \
  "$HOME_DIR" "$ROOT" "$ROOT/bin/fm-cloud-bridge.sh" "$STATE" "$DATA" "$CONFIG" "$ID"
fm_backend_herdr_send_text_line "$T" "export PATH=$Q_FAKEBIN:\$PATH FM_CLOUD_CLAUDE=$Q_CLOUD" \
  || fail "could not prepare the pane environment"
fm_backend_herdr_send_text_line "$T" "$LAUNCH" || fail "could not start the bridge in the pane"
wait_until 100 bridge_drawn || fail "the bridge never drew its screen: $(screen)"

wait_until 50 agent_state_is alive \
  || fail "a running bridge on Herdr must read alive, got '$(fm_backend_agent_state herdr "$T")'"
pass "real herdr: a running claude-cloud bridge reads as a live agent"

OUT=$(run_control "$ID" interrupt) || fail "interrupt against a running bridge should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered $ID harness=claude-cloud backend=herdr verified=agent-alive"*) : ;;
  *) fail "interrupt should report the agent-alive proof, got: $OUT" ;;
esac
wait_until 50 sent_has "interrupt" || fail "the interrupt request never reached the cloud session: $(cat "$SENT")"
pass "real herdr: fm-control interrupt reaches the cloud session through the bridge"

OUT=$(run_control "$ID" exit) || fail "exit against a running bridge should succeed: $OUT"
case "$OUT" in
  "already-stopped $ID"*) fail "exit must stop the running bridge, not report it already stopped: $OUT" ;;
esac
agent_state_is dead || fail "the pane must read dead once the bridge exits, got '$(fm_backend_agent_state herdr "$T")'"
wait_until 50 sent_has "exit" || fail "the exit request never reached the cloud session: $(cat "$SENT")"
REG=$(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -r '.error.code // .result.agent.agent // empty')
[ "$REG" = agent_not_found ] || fail "the exited bridge must release its Herdr registration, agent get reads '$REG'"
pass "real herdr: fm-control exit stops the bridge, sends the exit request, and releases the registration"

# Restart the bridge, then hand the task to a local claude worker.
fm_backend_herdr_send_text_line "$T" "clear; $LAUNCH" || fail "could not restart the bridge"
wait_until 100 bridge_drawn || fail "the restarted bridge never drew its screen: $(screen)"
wait_until 50 agent_state_is alive || fail "the restarted bridge must read alive"
: > "$SENT"
OUT=$(run_control "$ID" relaunch --harness claude --note "the cloud ship is done; deliver it locally") \
  || fail "relaunch --harness claude from a running bridge should succeed: $OUT"
case "$OUT" in
  *"relaunched $ID harness=claude from=claude-cloud"*) : ;;
  *) fail "relaunch should report the local claude replacement, got: $OUT" ;;
esac
[ -e "$SCRATCH/local-claude-launched" ] || fail "the local claude replacement was never launched"
sent_has "exit" || fail "the superseded cloud session was never sent an exit request: $(cat "$SENT")"
[ "$(fm_meta_get "$STATE/$ID.meta" harness)" = claude ] || fail "the task record must name the local harness"
agent_state_is alive || fail "the local replacement must read alive"
if pgrep -f "fm-cloud-bridge.sh $STATE" >/dev/null 2>&1; then
  fail "the superseded bridge is still running after the relaunch"
fi
pass "real herdr: relaunch --harness claude stops the bridge and launches the local worker in its pane"

fm_backend_herdr_kill "$T" 2>/dev/null || true
