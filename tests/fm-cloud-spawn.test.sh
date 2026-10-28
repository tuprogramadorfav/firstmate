#!/usr/bin/env bash
# Spawn and teardown behavior for the claude-cloud worker runtime.
#
# The real bin/fm-spawn.sh runs against a fake `claude` (login state and
# `--cloud` session creation), a fake `gh` (push permission), and a project
# whose github.com origin is rewritten to a local bare repository, so the
# return branch is real. What is pinned:
#   1. A scout and a ship launch create the cloud session from the rendered
#      cloud instructions, record its id, URL, and generation in the task
#      record, arm the busy record, install no Claude hooks in the worktree, and run
#      the bridge in the local endpoint.
#   2. A missing login, a non-subscription login, a non-GitHub origin, missing
#      push access, a secondmate, a local-only ship, and an unsupported backend
#      each refuse
#      before any task record exists or any session is created, naming the
#      reason; nothing falls back to a local launch.
#   3. A session the CLI does not report created stops the spawn, and a launch
#      that fails after creation sends the created session an exit request.
#   4. A relaunch creates a new session and sends the superseded one an exit
#      request when its bridge never did.
#   5. Cleanup tells the session the task is closed and deletes its return
#      branch from origin, also after the task was handed to a local harness.
#   6. config/cloud-environment selects the session's environment by project,
#      and a malformed line refuses before anything is created.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP=$(fm_test_tmproot fm-cloud-spawn) || exit 1
fm_git_identity

case_dir="$TMP/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake")
mv "$fakebin/tmux" "$fakebin/tmux-world"
# The spawn-world tmux, plus a capture that shows the bridge header once the
# launch staged the bridge command, as the real bridge renders it.
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ] && [ -n "${FM_FAKE_BRIDGE_ID:-}" ] && [ -s "${FM_FAKE_LAUNCH_LOG:-/nonexistent}" ] \
   && grep -q 'fm-cloud-bridge.sh' "$FM_FAKE_LAUNCH_LOG"; then
  printf 'fm-cloud-bridge  task %s (scout)\n\n\xe2\x9d\xaf \n' "$FM_FAKE_BRIDGE_ID"
  exit 0
fi
exec "$(dirname "$0")/tmux-world" "$@"
SH
chmod +x "$fakebin/tmux"
cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  case "${FM_FAKE_CLAUDE_AUTH:-sub}" in
    sub) printf '{"loggedIn":true,"authMethod":"claude.ai"}\n' ;;
    apikey) printf '{"loggedIn":true,"authMethod":"apiKey"}\n' ;;
    *) printf '{"loggedIn":false}\n' ;;
  esac
  exit 0
fi
if [ "${1:-}" = -p ] && [ "${2:-}" = --cloud ]; then
  { printf '>>> %s\n' "$3"; cat; printf '\n<<<\n'; } >> "$FM_FAKE_CLOUD_COUNT.sent"
  printf '{"ok":true,"session_id":"%s"}\n' "$3"
  exit 0
fi
prompt=
prev=
for arg in "$@"; do
  [ "$prev" != --cloud ] || prompt=$arg
  prev=$arg
done
if [ -n "$prompt" ]; then
  n=$(cat "$FM_FAKE_CLOUD_COUNT" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%s\n' "$n" > "$FM_FAKE_CLOUD_COUNT"
  printf '%s' "$prompt" > "$FM_FAKE_CLOUD_COUNT.prompt.$n"
  for arg in "$@"; do [ "$arg" = "$prompt" ] || printf '%s\n' "$arg"; done > "$FM_FAKE_CLOUD_COUNT.argv.$n"
  if [ "${FM_FAKE_CLOUD_HANG:-0}" = 1 ]; then
    printf 'Quick safety check: Is this a project you created or one you trust?\n'
    exec sleep 600
  fi
  if [ "${FM_FAKE_CLOUD_FAIL:-0}" = 1 ]; then
    printf 'Error: Could not create a cloud session for this repository.\n'
    exit 1
  fi
  printf 'Created cloud session: fake\r\nView: https://claude.ai/code/session_fake%s?from=cli&m=0\r\nResume with: claude --teleport session_fake%s\r\n' "$n" "$n"
  exit 0
fi
exit 0
SH
chmod +x "$fakebin/claude"
cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ] && [ "${2:-}" = repos/owner/repo ]; then
  printf '%s\n' "${FM_FAKE_GH_PUSH:-true}"
  exit 0
fi
exit 0
SH
chmod +x "$fakebin/gh"

home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home"
fm_git_worktree "$proj" "$wt" cloud-test
git -C "$wt" checkout -q --detach
origin_git="$proj.origin.git"
git -C "$proj" remote set-url origin https://github.com/owner/repo
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$origin_git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/owner/repo
export FM_FAKE_CLOUD_COUNT="$case_dir/cloud-count"

hometag=$(FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-backend-hometag-lib.sh"; fm_backend_hometag' _ "$ROOT")

cloud_spawn() {  # <id> <args...>
  local id=$1
  shift
  FM_FAKE_BRIDGE_ID=$id FM_FAKE_LAUNCH_LOG="$case_dir/$id.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@"
}

created_count() { cat "$FM_FAKE_CLOUD_COUNT" 2>/dev/null || echo 0; }

test_scout_launch() {
  local out meta prompt launch
  fm_test_spawn_brief "$home" cs1 'investigate the cloud'
  out=$(cloud_spawn cs1 --scout --harness claude-cloud) || fail "scout spawn failed: $out"
  meta=$(cat "$home/state/cs1.meta")
  assert_contains "$meta" "harness=claude-cloud" "the task records the cloud runtime"
  assert_contains "$meta" "cloud_session=session_fake1" "the task records the session id"
  assert_contains "$meta" "cloud_url=https://claude.ai/code/session_fake1" "the task records the session URL"
  prompt=$(cat "$FM_FAKE_CLOUD_COUNT.prompt.1")
  assert_contains "$prompt" "# Cloud runtime contract" "the session receives the cloud contract"
  assert_contains "$prompt" "publish it with \`fm-cloud report <file>\`" "a scout is told how to publish its report"
  assert_contains "$prompt" ": \"\${FM_CLOUD_STATUS_BRANCH:=fm-cloud/$hometag/cs1}\"" "the helper carries the return branch"
  assert_contains "$prompt" "investigate the cloud" "the ordinary launch brief follows the contract"
  assert_equals "$prompt" "$(cat "$home/data/cs1/cloud-launch-brief.md")" "the exact instructions are kept in the task's data"
  launch=$(cat "$case_dir/cs1.launch")
  assert_contains "$launch" "bin/fm-cloud-bridge.sh' '" "the endpoint runs the bridge"
  assert_contains "$launch" "'cs1'" "the bridge is bound to the task"
  [ -s "$home/state/cs1.busy-gen" ] || fail "the busy record is armed for the bridge"
  [ ! -e "$wt/.claude/settings.local.json" ] || fail "no Claude hooks are installed for a cloud worker"
  grep -qF "\"$wt\"" "$home/user-home/.claude.json" 2>/dev/null \
    || fail "the worktree is pre-registered as trusted, because claude --cloud starts like an interactive session there"
  pass "a scout launch creates and records the cloud session and runs the bridge"
}

test_ship_launch() {
  local out prompt
  fm_test_spawn_brief "$home" cs2 'ship a cloud change'
  out=$(cloud_spawn cs2 --mode direct-PR --yolo off --harness claude-cloud) || fail "ship spawn failed: $out"
  prompt=$(cat "$FM_FAKE_CLOUD_COUNT.prompt.$(created_count)")
  assert_contains "$prompt" "create the task branch \`fm/cs2\` from it" "the ship is told its task branch"
  assert_contains "$prompt" "fetch \`origin/main\`" "the ship starts from the base branch"
  assert_contains "$prompt" "runs this task's delivery path (mode=direct-PR)" "the ship is told delivery runs locally"
  assert_contains "$prompt" "never run no-mistakes, open a pull request, merge" "the cloud never delivers on its own"
  pass "a ship launch tells the cloud session its branch and leaves delivery local"
}

test_environment_selection() {
  local out n
  printf '# environments\nproject env_01Project\n* ccpool_fallback\n' > "$home/config/cloud-environment"
  fm_test_spawn_brief "$home" ce1
  out=$(cloud_spawn ce1 --scout --harness claude-cloud) || fail "spawn with an environment failed: $out"
  n=$(created_count)
  assert_equals $'--settings\n{"remote":{"defaultEnvironmentId":"env_01Project"}}\n--cloud' "$(cat "$FM_FAKE_CLOUD_COUNT.argv.$n")" \
    "the project's hosted environment is selected for this session only"
  printf 'other env_01Other\n* ccpool_fallback\n' > "$home/config/cloud-environment"
  fm_test_spawn_brief "$home" ce2
  out=$(cloud_spawn ce2 --scout --harness claude-cloud) || fail "spawn with a fallback environment failed: $out"
  n=$(created_count)
  assert_equals $'--environment\nccpool_fallback\n--cloud' "$(cat "$FM_FAKE_CLOUD_COUNT.argv.$n")" \
    "the * line selects a self-hosted environment"
  printf 'project not-an-id\n' > "$home/config/cloud-environment"
  refuses ce3 "line 1 names 'not-an-id'" --scout --harness claude-cloud
  rm -f "$home/config/cloud-environment"
  pass "config/cloud-environment selects the session's environment and malformed lines refuse"
}

refuses() {  # <id> <expected-text> <spawn args...>
  local id=$1 want=$2 before out
  shift 2
  before=$(created_count)
  fm_test_spawn_brief "$home" "$id"
  if out=$(cloud_spawn "$id" "$@"); then
    fail "$id: the spawn was accepted: $out"
  fi
  assert_contains "$out" "$want" "$id refusal names the reason"
  [ ! -e "$home/state/$id.meta" ] || fail "$id: a refused spawn left a task record"
  assert_equals "$before" "$(created_count)" "$id: a refused spawn created no cloud session"
  [ ! -e "$case_dir/$id.launch" ] || fail "$id: a refused spawn launched something locally"
}

test_preflight_refusals() {
  FM_FAKE_CLAUDE_AUTH=none refuses cr1 "needs a Claude Code login" --scout --harness claude-cloud
  FM_FAKE_CLAUDE_AUTH=apikey refuses cr2 "needs a claude.ai subscription login" --scout --harness claude-cloud
  FM_FAKE_GH_PUSH=false refuses cr3 "needs push access to github.com/owner/repo" --scout --harness claude-cloud
  refuses cr4 "runs ship and scout tasks only" --secondmate --harness claude-cloud
  refuses cr7 "cannot ship mode=local-only" --mode local-only --yolo off --harness claude-cloud
  refuses cr5 "supported on the tmux and herdr backends only; backend=zellij" --scout --harness claude-cloud --backend zellij
  git -C "$proj" remote set-url origin "file://$origin_git"
  refuses cr6 "needs the project's origin on github.com" --scout --harness claude-cloud
  git -C "$proj" remote set-url origin https://github.com/owner/repo
  pass "missing prerequisites refuse before any record, session, or local launch"
}

test_creation_failure_and_abort() {
  local out before
  before=$(created_count)
  fm_test_spawn_brief "$home" cf1
  if out=$(FM_FAKE_CLOUD_FAIL=1 cloud_spawn cf1 --scout --harness claude-cloud); then
    fail "a failed creation was accepted: $out"
  fi
  assert_contains "$out" "did not report a created session" "the creation failure is named"
  assert_contains "$out" "nothing was launched locally in its place" "no local fallback is claimed"
  [ ! -e "$home/state/cf1.meta" ] || fail "a failed creation left a task record"
  assert_equals $((before + 1)) "$(created_count)" "exactly one creation was attempted"
  # A creation stuck on a prompt is stopped and named rather than left hanging.
  fm_test_spawn_brief "$home" cf3
  local started
  started=$(date +%s)
  if out=$(FM_FAKE_CLOUD_HANG=1 FM_CLOUD_CREATE_TIMEOUT=2 cloud_spawn cf3 --scout --harness claude-cloud); then
    fail "a hung creation was accepted: $out"
  fi
  [ $(( $(date +%s) - started )) -lt 60 ] || fail "a hung creation was not stopped at its time limit"
  assert_contains "$out" "still waiting after 2s, stopped" "the hang is named"
  assert_contains "$out" "Quick safety check" "the prompt it stopped on is shown"
  [ ! -e "$home/state/cf3.meta" ] || fail "a hung creation left a task record"
  # The bridge never renders: the created session gets an exit request.
  fm_test_spawn_brief "$home" cf2
  if out=$(FM_FAKE_BRIDGE_ID=never-shown FM_CLOUD_BRIDGE_READY_POLLS=2 FM_FAKE_LAUNCH_LOG="$case_dir/cf2.launch" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" cf2 "$proj" --scout --harness claude-cloud); then
    fail "a launch whose bridge never started was accepted: $out"
  fi
  assert_contains "$out" "bridge for cf2 did not start" "the unstarted bridge is named"
  local created
  created=$(created_count)
  assert_contains "$(cat "$FM_FAKE_CLOUD_COUNT.sent")" ">>> session_fake$created"$'\n'"FIRSTMATE CONTROL exit" \
    "the created session is sent an exit request"
  pass "a failed creation stops the spawn and a failed launch stops the created session"
}

test_relaunch_supersedes_generation() {
  local out meta
  fm_test_spawn_brief "$home" rl1
  out=$(cloud_spawn rl1 --scout --harness claude-cloud) || fail "first spawn failed: $out"
  local first
  first=$(sed -n 's/^cloud_session=//p' "$home/state/rl1.meta")
  # The bridge died without sending an exit (no ended generation recorded),
  # so the endpoint's foreground is the pane shell again: a per-case ps
  # answers the tty query the tmux classifier makes with a lone shell and
  # passes every other query through.
  local relaunch_bin="$case_dir/relaunch-bin"
  mkdir -p "$relaunch_bin"
  cat > "$relaunch_bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -t ]; then
  case "$*" in
    *comm=*) printf '101 101 101 zsh\n' ;;
    *args=*) printf '101 101 101 zsh\n' ;;
  esac
  exit 0
fi
case "$*" in *'-p 101'*) printf 'zsh\n'; exit 0 ;; esac
exec /bin/ps "$@"
SH
  chmod +x "$relaunch_bin/ps"
  : > "$case_dir/rl1.launch"
  out=$(FM_FAKE_BRIDGE_ID=rl1 FM_FAKE_LAUNCH_LOG="$case_dir/rl1.launch" \
    PATH="$relaunch_bin:$PATH" fm_test_run_spawn "$home" "$wt" "$fakebin" rl1 --relaunch) || fail "relaunch failed: $out"
  meta=$(cat "$home/state/rl1.meta")
  assert_contains "$meta" "cloud_session=session_fake$(created_count)" "a relaunch records its new session"
  assert_not_contains "$meta" "cloud_session=$first" "the superseded session is no longer recorded"
  assert_contains "$(cat "$FM_FAKE_CLOUD_COUNT.sent")" ">>> $first"$'\n'"FIRSTMATE CONTROL exit" \
    "the superseded session is sent an exit request"
  pass "a relaunch starts a new session and stops the superseded one"
}

test_teardown_closes_channel() {
  local out
  printf '# Report\n' > "$home/data/cs1/report.md"
  # The cloud session's return branch, as its helper would have pushed it.
  git -C "$wt" push -q "file://$origin_git" "HEAD:refs/heads/fm-cloud/$hometag/cs1"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-captain-hold.sh" complete cs1 --none 2>&1) \
    || fail "the report's captain-call inventory could not be recorded: $out"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_PANE_PATH="$wt" TMUX=fake,1,0 PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" cs1 2>&1) || fail "cleanup failed: $out"
  if git --git-dir="$origin_git" rev-parse -q --verify "refs/heads/fm-cloud/$hometag/cs1" >/dev/null; then
    fail "cleanup left the cloud return branch on origin"
  fi
  assert_contains "$(cat "$FM_FAKE_CLOUD_COUNT.sent")" ">>> session_fake1"$'\n'"FIRSTMATE CONTROL exit: firstmate has finished with this task" \
    "cleanup tells the session the task is closed"
  [ ! -e "$home/state/cs1.cloud-sync" ] || fail "cleanup left the bridge's relay record"
  pass "cleanup tells the session the task is closed and deletes its return branch"
}

test_teardown_after_local_handoff() {
  local out session
  fm_test_spawn_brief "$home" ho1
  out=$(cloud_spawn ho1 --scout --harness claude-cloud) || fail "spawn failed: $out"
  session=$(sed -n 's/^cloud_session=//p' "$home/state/ho1.meta")
  # The task was handed to a local harness: its record no longer names the
  # cloud runtime or session, while the bridge's relay record remains.
  sed -i.bak -e 's/^harness=claude-cloud$/harness=claude/' -e '/^cloud_/d' "$home/state/ho1.meta"
  rm -f "$home/state/ho1.meta.bak"
  printf 'session=%s\n' "$session" > "$home/state/ho1.cloud-sync"
  printf '# Report\n' > "$home/data/ho1/report.md"
  git -C "$wt" push -q "file://$origin_git" "HEAD:refs/heads/fm-cloud/$hometag/ho1"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-captain-hold.sh" complete ho1 --none 2>&1) \
    || fail "the report's captain-call inventory could not be recorded: $out"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_PANE_PATH="$wt" TMUX=fake,1,0 PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" ho1 2>&1) || fail "cleanup failed: $out"
  if git --git-dir="$origin_git" rev-parse -q --verify "refs/heads/fm-cloud/$hometag/ho1" >/dev/null; then
    fail "cleanup after a local handoff left the cloud return branch on origin"
  fi
  assert_contains "$(cat "$FM_FAKE_CLOUD_COUNT.sent")" ">>> $session"$'\n'"FIRSTMATE CONTROL exit: firstmate has finished with this task" \
    "cleanup after a local handoff still closes the session"
  pass "cleanup after a local handoff still closes the cloud session and its return branch"
}

fm_test_run \
  test_scout_launch \
  test_teardown_closes_channel \
  test_teardown_after_local_handoff \
  test_ship_launch \
  test_environment_selection \
  test_preflight_refusals \
  test_creation_failure_and_abort \
  test_relaunch_supersedes_generation
