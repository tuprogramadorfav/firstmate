#!/usr/bin/env bash
# Behavior tests for the claude-cloud worker runtime's task channel.
#
# The real bridge (bin/fm-cloud-bridge.sh) runs against a local bare
# repository standing in for the project's GitHub origin and a fake Claude Code
# CLI that records every message queued into the session, while the real cloud
# helper (bin/fm-cloud-worker.sh, rendered exactly as bin/fm-cloud-lib.sh embeds
# it in the cloud launch instructions) plays the cloud session from a second
# clone. What is pinned:
#   1. A cloud status line reaches state/<id>.status verbatim, once, and moves
#      the busy record (working opens a turn, any other state closes it), and a
#      restarted bridge relays only new lines.
#   2. A local steering record is sent into the session once, and moves into
#      handled/ only once the cloud worker acknowledges it.
#   3. A ship's done: line is relayed only after the pushed task branch is
#      fast-forwarded into the local copy; a done: with no pushed branch
#      becomes a blocked: line instead.
#   4. A scout's published report lands at data/<id>/report.md.
#   5. Escape sends the session an interrupt request and Ctrl-C an exit
#      request that ends the bridge; a session the service reports archived
#      counts as stopped.
#   6. A session that never reports gets exactly one blocked: line, also when
#      a superseded session keeps writing to the same return branch, whose
#      lines are never relayed.
#   7. The bridge is a recognized agent process and its screen reads as an
#      empty composer, so the control plane's exit preconditions hold.
#   8. The creation transcript parser extracts the session id and URL.
#   9. A status push rejected because another session moved the return branch
#      is rebuilt on the new head, so no line from either session is lost.
#  10. The local CLI runs without the Herdr pane identity, both to create a
#      session and to message one, so Claude Code's Herdr integration cannot
#      claim the task pane and hide the bridge's own registration
#      (tests/fm-cloud-bridge-herdr-e2e.test.sh drives that against Herdr).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-cloud-bridge) || exit 1
fm_git_identity
# A bridge inside a Herdr pane reports that pane to Herdr's agent registry, so
# a run from the developer's own Herdr pane must not hand the bridges it starts
# that pane's identity. tests/fm-cloud-bridge-herdr-e2e.test.sh covers Herdr.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

BRIDGE_PID=
FIFO_FD_OPEN=0

# The fake CLI: `-p --cloud <session> --output-format json` reads the message
# on stdin and appends it to <sent-log> framed by its session, answering with
# the CLI's typed result. FM_FAKE_CLOUD_GONE=1 answers as an archived session.
write_fake_claude() {  # <path> <sent-log>
  cat > "$1" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -p ] && [ "\${2:-}" = --cloud ]; then
  if [ "\${FM_FAKE_CLOUD_GONE:-0}" = 1 ]; then
    printf '{"ok":false,"session_id":"%s","error":"cloud session %s is archived and cannot accept new messages"}\n' "\$3" "\$3"
    exit 1
  fi
  { printf '>>> %s\n' "\$3"; cat; printf '\n<<<\n'; } >> '$2'
  printf '{"ok":true,"session_id":"%s","url":"https://claude.ai/code/%s"}\n' "\$3" "\$3"
  exit 0
fi
exit 1
SH
  chmod +x "$1"
}

# One isolated home, origin, local copy, and cloud clone per case.
setup_world() {  # <case> <kind>
  local name=$1 kind=$2
  W="$TMP/$name"
  mkdir -p "$W/home/state" "$W/home/data" "$W/home/config"
  STATE="$W/home/state"
  DATA="$W/home/data"
  CONFIG="$W/home/config"
  fm_git_init_commit "$W/project"
  git clone -q --bare "$W/project" "$W/origin.git"
  git -C "$W/project" remote add origin "file://$W/origin.git"
  git clone -q "file://$W/origin.git" "$W/wt"
  git -C "$W/wt" checkout -q --detach
  git clone -q "file://$W/origin.git" "$W/cloud"
  ID=$name
  SESSION="session_test$name"
  SENT="$W/sent.log"
  : > "$SENT"
  write_fake_claude "$W/claude" "$SENT"
  BUSY_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID")
  fm_write_meta "$STATE/$ID.meta" \
    "window=fm:$ID" "endpoint_task_id=$ID" "worktree=$W/wt" "project=$W/project" \
    "harness=claude-cloud" "kind=$kind" "branch=fm/$ID" "mode=no-mistakes" \
    "busy_gen=$BUSY_GEN" "spawn_gen=s1.$name" "cloud_session=$SESSION" "cloud_url=https://claude.ai/code/$SESSION"
  : > "$STATE/$ID.status"
  printf 'task body\n' > "$W/brief.md"
  KIND=$kind
  render_helper "s1.$name" "$W/fm-cloud"
}

# The helper rendered for one session incarnation, installed as the cloud
# session would install it.
render_helper() {  # <spawn-gen> <path>
  FM_HOME="$W/home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-cloud-lib.sh"; fm_cloud_render_prompt "$2" "$3" "$4" no-mistakes "fm/$2" main owner/repo "$5" "$1"' \
    _ "$ROOT" "$ID" "$1" "$KIND" "$W/brief.md" > "$2.prompt.md"
  sed -n '/^--- fm-cloud helper begin ---$/,/^--- fm-cloud helper end ---$/p' "$2.prompt.md" \
    | sed '1d;$d' > "$2"
  chmod +x "$2"
}

status_log_on_origin() {  # <spawn-gen>
  local branch
  branch=$(FM_HOME="$W/home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-cloud-lib.sh"; fm_cloud_status_branch "$2"' _ "$ROOT" "$ID")
  git --git-dir="$W/origin.git" show "refs/heads/$branch:status/$1.log"
}

cloud() {  # <args...> - run the helper from the cloud clone
  (cd "$W/cloud" && "$W/fm-cloud" "$@")
}

start_bridge() {
  rm -f "$W/keys"
  mkfifo "$W/keys"
  # Job control gives the bridge its own process group with SIGINT not
  # ignored, as a foreground program in a terminal has.
  set -m
  FM_HOME="$W/home" FM_CLOUD_CLAUDE="$W/claude" FM_CLOUD_POLL_SECS=1 \
    FM_CLOUD_FIRST_STATUS_SECS=${FIRST_STATUS_SECS:-900} \
    "$ROOT/bin/fm-cloud-bridge.sh" "$STATE" "$DATA" "$CONFIG" "$ID" < "$W/keys" > "$W/screen" 2>&1 &
  BRIDGE_PID=$!
  set +m
  exec 9>"$W/keys"
  FIFO_FD_OPEN=1
}

stop_bridge() {
  if [ "$FIFO_FD_OPEN" = 1 ]; then
    exec 9>&-
    FIFO_FD_OPEN=0
  fi
  if [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
    BRIDGE_PID=
  fi
}

wait_for() {  # <description> <command...>
  local desc=$1 i=0
  shift
  while [ "$i" -lt 150 ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  fail "timed out waiting for $desc"$'\n'"--- screen ---"$'\n'"$(cat "$W/screen" 2>/dev/null)"
}

status_has() { grep -qF -- "$1" "$STATE/$ID.status"; }
sent_has() { grep -qF -- "$1" "$SENT"; }
busy_state() { sed -n 's/.* state=\([a-z]*\) source=\([a-z-]*\).*/\1 \2/p' "$STATE/$ID.busy-state"; }
busy_is() { [ "$(busy_state)" = "$1" ]; }

test_status_relay_and_busy() {
  setup_world relay ship
  start_bridge
  cloud status 'working [at=100]: cloud session started'
  wait_for "the working line" status_has 'working [at=100]: cloud session started'
  wait_for "a busy cloud-bridge record" busy_is 'busy cloud-bridge'
  cloud status 'needs-decision [at=101] [key=k1]: pick a or b'
  wait_for "the decision line" status_has 'needs-decision [at=101] [key=k1]: pick a or b'
  wait_for "an idle cloud-bridge record" busy_is 'idle cloud-bridge'
  [ -e "$STATE/$ID.turn-ended" ] || fail "an idle relay must notify the watcher through turn-ended"
  assert_equals 2 "$(grep -c . "$STATE/$ID.status")" "each cloud line is relayed exactly once"
  stop_bridge
  start_bridge
  cloud status 'working [at=102]: resumed'
  wait_for "the line after restart" status_has 'working [at=102]: resumed'
  assert_equals 3 "$(grep -c . "$STATE/$ID.status")" "a restarted bridge relays only new lines"
  stop_bridge
  pass "cloud status lines relay verbatim once and drive the busy record"
}

test_steering_sent_once_and_acked() {
  setup_world inbox ship
  mkdir -p "$STATE/$ID.inbox"
  printf 'schema=fm-task-inbox.v1\nat=2026-10-27T00:00:00Z\n--\nplease also update the docs\n' > "$STATE/$ID.inbox/001.msg"
  start_bridge
  wait_for "the record sent into the session" sent_has 'Firstmate steering record inbox/001.msg'
  assert_contains "$(cat "$SENT")" ">>> $SESSION" "the record is addressed to the recorded session"
  assert_contains "$(cat "$SENT")" "please also update the docs" "the record body is sent"
  assert_not_contains "$(cat "$SENT")" "schema=fm-task-inbox.v1" "the record header stays local"
  sleep 3
  assert_equals 1 "$(grep -c 'Firstmate steering record inbox/001.msg' "$SENT")" "a record is sent once"
  [ -f "$STATE/$ID.inbox/001.msg" ] || fail "a sent record stays unhandled until the cloud worker acknowledges it"
  cloud ack inbox/001.msg
  wait_for "the acknowledged record in handled/" test -f "$STATE/$ID.inbox/handled/001.msg"
  [ ! -e "$STATE/$ID.inbox/001.msg" ] || fail "an acknowledged record must leave the inbox root"
  stop_bridge
  pass "steering records reach the session once and are handled only on acknowledgement"
}

test_ship_done_syncs_local_copy() {
  setup_world shipdone ship
  start_bridge
  git -C "$W/cloud" checkout -q -b "fm/$ID" origin/main
  printf 'change\n' > "$W/cloud/change.txt"
  git -C "$W/cloud" add change.txt
  git -C "$W/cloud" commit -qm change
  git -C "$W/cloud" push -q -u origin "fm/$ID"
  local head
  head=$(git -C "$W/cloud" rev-parse HEAD)
  cloud status "done [at=200]: pushed fm/$ID at $head: change"
  wait_for "the relayed done line" status_has "done [at=200]: pushed fm/$ID at $head"
  assert_equals "fm/$ID" "$(git -C "$W/wt" symbolic-ref --short HEAD)" "the local copy is on the task branch"
  assert_equals "$head" "$(git -C "$W/wt" rev-parse HEAD)" "the local copy is at the pushed head"
  stop_bridge
  pass "a ship's done line is relayed after the local copy reaches the pushed head"
}

test_ship_done_without_branch_blocks() {
  setup_world nobranch ship
  start_bridge
  cloud status 'done [at=300]: pushed fm/nobranch at abc: nothing'
  wait_for "the blocked replacement line" status_has 'blocked [at='
  assert_contains "$(cat "$STATE/$ID.status")" "branch fm/nobranch is not on origin" "the blocked line names the missing branch"
  ! status_has 'done [at=300]' || fail "an unverifiable done must not be relayed as done"
  stop_bridge
  pass "a done line without a pushed branch is relayed as blocked"
}

test_scout_report_copied() {
  setup_world scoutrep scout
  start_bridge
  printf '# Findings\nall good\n' > "$W/report.md"
  cloud report "$W/report.md"
  cloud status 'done [at=400]: report published'
  wait_for "the copied report" test -f "$DATA/$ID/report.md"
  assert_equals "$(cat "$W/report.md")" "$(cat "$DATA/$ID/report.md")" "the report arrives byte for byte"
  wait_for "the scout done line" status_has 'done [at=400]: report published'
  stop_bridge
  pass "a scout's published report is copied into data/<id>/report.md"
}

test_keys_send_lifecycle_requests() {
  setup_world keys ship
  start_bridge
  wait_for "a rendered screen" grep -q 'fm-cloud-bridge  task keys' "$W/screen"
  printf '\033' >&9
  wait_for "the interrupt request" sent_has 'FIRSTMATE CONTROL interrupt'
  # An escape sequence (an arrow key) is not an interrupt.
  printf '\033[A' >&9
  sleep 1
  assert_equals 1 "$(grep -c 'FIRSTMATE CONTROL interrupt' "$SENT")" "only a lone Escape interrupts"
  kill -INT "$BRIDGE_PID"
  local i=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  ! kill -0 "$BRIDGE_PID" 2>/dev/null || fail "Ctrl-C must end the bridge"
  wait "$BRIDGE_PID"
  expect_code 0 $? "bridge exit after a delivered exit request"
  BRIDGE_PID=
  sent_has 'FIRSTMATE CONTROL exit' || fail "the exit request reaches the session"
  assert_equals "ended_session=$SESSION" "$(grep '^ended_session=' "$STATE/$ID.cloud-sync")" "the ended session is recorded"
  # A session the service reports archived can do no more work.
  if ! FM_CLOUD_CLAUDE="$W/claude" FM_FAKE_CLOUD_GONE=1 FM_HOME="$W/home" FM_ROOT="$ROOT" \
    bash -c '. "$1/bin/fm-cloud-lib.sh"; fm_cloud_control "$2" exit' _ "$ROOT" "$SESSION"; then
    fail "an archived session must count as stopped"
  fi
  stop_bridge
  pass "Escape and Ctrl-C send the session interrupt and exit requests"
}

test_silent_session_reported_once() {
  setup_world silent ship
  FIRST_STATUS_SECS=1 start_bridge
  wait_for "the silence line" status_has 'has not reported within'
  sleep 3
  assert_equals 1 "$(grep -c 'has not reported within' "$STATE/$ID.status")" "silence is reported exactly once"
  stop_bridge
  pass "a session that never reports is surfaced once as blocked"
}

test_relaunched_silent_session_reported() {
  setup_world relsilent ship
  # The superseded session's log, which its own bridge already relayed.
  render_helper s0.previous "$W/fm-cloud-previous"
  (cd "$W/cloud" && "$W/fm-cloud-previous" status 'working [at=1]: previous session')
  printf 'session=session_previous\nrelayed=1\n' > "$STATE/$ID.cloud-sync"
  FIRST_STATUS_SECS=2 start_bridge
  # The superseded session answers its exit request after this one started.
  (cd "$W/cloud" && "$W/fm-cloud-previous" status 'paused [at=2]: exiting on firstmate request')
  wait_for "the silence line" status_has 'has not reported within'
  ! status_has 'previous session' || fail "the superseded session's lines must not be relayed"
  ! status_has 'exiting on firstmate request' || fail "the superseded session's exit line must not be relayed"
  stop_bridge
  pass "a relaunched session that never reports is surfaced as blocked, whatever its predecessor writes"
}

test_rejected_push_rebuilt_on_new_head() {
  setup_world rebuild ship
  cloud status 'working [at=10]: replacement started'
  # The superseded session answers its exit request after the replacement
  # already cached the branch head.
  git clone -q "file://$W/origin.git" "$W/cloud-previous"
  render_helper s0.previous "$W/fm-cloud-previous"
  (cd "$W/cloud-previous" && "$W/fm-cloud-previous" status 'paused [at=11]: exiting on firstmate request') \
    || fail "the superseded session could not push its line"
  cloud status 'working [at=12]: replacement continues' || fail "a push rejected by the moved branch was not retried on its new head"
  cloud ack inbox/001.msg || fail "an ack after the rebuild must push"
  assert_equals $'working [at=10]: replacement started\nworking [at=12]: replacement continues' \
    "$(status_log_on_origin s1.rebuild)" "the replacement's lines are kept in order in its own log"
  assert_equals 'paused [at=11]: exiting on firstmate request' \
    "$(status_log_on_origin s0.previous)" "the rebuild keeps the superseded session's line in its log"
  local branch
  branch=$(FM_HOME="$W/home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-cloud-lib.sh"; fm_cloud_status_branch "$2"' _ "$ROOT" "$ID")
  assert_equals inbox/001.msg "$(git --git-dir="$W/origin.git" show "refs/heads/$branch:acks")" "the ack is recorded once"
  pass "a rejected status push is rebuilt on the moved branch head"
}

test_bridge_is_agent_with_empty_composer() {
  setup_world screen ship
  start_bridge
  wait_for "a rendered screen" grep -q 'fm-cloud-bridge  task screen' "$W/screen"
  local verdict screen cls
  screen=$(sed 's/\x1b\[[0-9;]*[HJ]//g' "$W/screen")
  verdict=$(bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_classify_screen "$(printf "styled=0\ncursor=0")" "$2"' _ "$ROOT" "$screen")
  assert_equals empty "$verdict" "the bridge screen reads as an empty composer"
  cls=$(bash -c '. "$1/bin/fm-agent-process-lib.sh"; fm_agent_process_classify_name fm-cloud-bridge' _ "$ROOT")
  assert_equals agent "$cls" "the anchored bridge process name is an agent"
  cls=$(bash -c '. "$1/bin/fm-agent-process-lib.sh"; fm_agent_process_classify bash fm-cloud-bridge \"\"' _ "$ROOT")
  assert_equals agent "$cls" "the bridge argv[0] under an interpreter name is an agent"
  cls=$(bash -c '. "$1/bin/fm-agent-process-lib.sh"; fm_agent_process_classify_name my-fm-cloud-bridge-x' _ "$ROOT")
  assert_equals other "$cls" "the bridge name is anchored, not a fragment match"
  stop_bridge
  pass "the bridge is a recognized agent with an empty composer row"
}

test_parse_create_transcript() {
  local log="$TMP/create.log" out
  printf 'Created cloud session: Probe\r\nView: https://claude.ai/code/session_01ABCdef?from=cli&m=0\r\nResume with: claude --teleport session_01ABCdef\r\n' > "$log"
  out=$(bash -c '. "$1/bin/fm-cloud-lib.sh"; fm_cloud_parse_create "$2"' _ "$ROOT" "$log")
  assert_equals $'session_01ABCdef\thttps://claude.ai/code/session_01ABCdef' "$out" "the session id and URL are parsed"
  printf 'Error: Attaching to an existing cloud session is not enabled for your account.\n' > "$log"
  if bash -c '. "$1/bin/fm-cloud-lib.sh"; fm_cloud_parse_create "$2"' _ "$ROOT" "$log" >/dev/null; then
    fail "a transcript without a created session must not parse"
  fi
  pass "the creation transcript parser extracts only a created session"
}

test_cli_runs_without_herdr_pane_identity() {
  local dir="$TMP/herdr-identity" out
  mkdir -p "$dir"
  # A fake CLI that records the Herdr identity it was started with.
  cat > "$dir/claude" <<SH
#!/usr/bin/env bash
printf 'env=%s pane=%s socket=%s\n' "\${HERDR_ENV:-}" "\${HERDR_PANE_ID:-}" "\${HERDR_SOCKET_PATH:-}" >> '$dir/seen'
cat >/dev/null
if [ "\${1:-}" = --cloud ]; then
  printf 'View: https://claude.ai/code/session_identity\n'
else
  printf '{"ok":true}\n'
fi
SH
  chmod +x "$dir/claude"
  printf 'prompt\n' > "$dir/prompt.md"
  # shellcheck disable=SC2016 # the single-quoted script expands in the inner shell
  out=$(env HERDR_ENV=1 HERDR_PANE_ID=w9:p9 HERDR_SOCKET_PATH="$dir/herdr.sock" \
    FM_HOME="$dir" FM_ROOT="$ROOT" FM_CLOUD_CLAUDE="$dir/claude" bash -c '
      . "$1/bin/fm-cloud-lib.sh"
      fm_cloud_create "$2" "$2/prompt.md" "$2/create.log" || exit 1
      printf "\n"
      fm_cloud_send session_identity hello || exit 1
      printf "pane-after=%s\n" "${HERDR_PANE_ID:-}"' _ "$ROOT" "$dir") \
    || fail "creating and messaging a session with a Herdr identity exported failed: $out"
  assert_equals $'env= pane= socket=\nenv= pane= socket=' "$(cat "$dir/seen")" \
    "neither the creation nor the message run sees the Herdr pane identity"
  case "$out" in
    *pane-after=w9:p9*) : ;;
    *) fail "the caller must keep its own Herdr identity, got: $out" ;;
  esac
  pass "the local CLI runs without the Herdr pane identity, and the caller keeps its own"
}

trap 'stop_bridge; fm_test_cleanup' EXIT
fm_test_run \
  test_status_relay_and_busy \
  test_steering_sent_once_and_acked \
  test_ship_done_syncs_local_copy \
  test_ship_done_without_branch_blocks \
  test_scout_report_copied \
  test_keys_send_lifecycle_requests \
  test_silent_session_reported_once \
  test_relaunched_silent_session_reported \
  test_rejected_push_rebuilt_on_new_head \
  test_bridge_is_agent_with_empty_composer \
  test_parse_create_transcript \
  test_cli_runs_without_herdr_pane_identity
