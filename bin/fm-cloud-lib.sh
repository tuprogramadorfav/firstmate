#!/usr/bin/env bash
# fm-cloud-lib.sh - the LOCAL half of the claude-cloud worker runtime.
#
# A claude-cloud ship or scout runs its agent in a Claude Code cloud session
# (claude.ai/code) instead of a local terminal. The installed CLI creates a
# session (`claude --cloud <prompt>`) and queues a message into an existing one
# (`claude -p <message> --cloud <session>`), but cannot attach to one, read its
# output, or stop or archive it (docs/verification/claude-cloud.md). So
# firstmate keeps an ordinary local endpoint for the task and runs
# bin/fm-cloud-bridge.sh in it: messages go TO the session through the CLI, and
# the session's status lines, steering acknowledgements, and scout report come
# BACK on one branch of the project's GitHub origin that only the cloud helper
# (bin/fm-cloud-worker.sh) writes. docs/cloud-workers.md owns the operator
# contract; this library owns the branch name, the spawn preflight, the cloud
# launch instructions, session creation, and sending to a session.
#
# Return branch (fm_cloud_status_branch): fm-cloud/<hometag>/<task-id>. The
# home tag (bin/fm-backend-hometag-lib.sh) keeps equal task ids in two homes
# that share one origin apart. A relaunch's replacement session continues the
# same branch, but each incarnation (the task record's spawn_gen) writes its own
# status log there (fm_cloud_status_log), so a superseded session's late lines
# are never read as its replacement's.
#
# Sourcing: requires FM_ROOT and FM_HOME for the home tag; set -u safe.
# FM_CLOUD_CLAUDE overrides the Claude Code executable for tests.

_FM_CLOUD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$_FM_CLOUD_LIB_DIR/fm-backend-hometag-lib.sh"

fm_cloud_status_branch() {  # <task-id>
  printf 'fm-cloud/%s/%s' "$(fm_backend_hometag)" "$1"
}

fm_cloud_status_log() {  # <spawn-gen>
  printf 'status/%s.log' "$1"
}

# owner/repo of a github.com origin URL, or nonzero for any other remote. The
# cloud session reaches only GitHub, so any other forge is refused at spawn.
# The configured URL is read rather than `remote get-url`, whose insteadOf
# rewriting would describe the transport instead of the repository.
fm_cloud_origin_slug() {  # <git-dir>
  local url slug
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  case "$url" in
    https://github.com/*) slug=${url#https://github.com/} ;;
    git@github.com:*) slug=${url#git@github.com:} ;;
    ssh://git@github.com/*) slug=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  slug=${slug%.git}
  slug=${slug%/}
  case "$slug" in
    */*/*|/*|*/|'') return 1 ;;
    */*) printf '%s' "$slug" ;;
    *) return 1 ;;
  esac
}

# Refuse a cloud launch the moment a precondition is missing, naming it. Checks
# what this machine can prove: the CLI, a claude.ai subscription login (cloud
# sessions need one; an API key cannot create them), a github.com origin, push
# access to it for the local gh login, which the local delivery path needs for
# the branch the cloud session pushes, and that the repository is private,
# because the return branch carries the task's status lines, steering record
# names, and scout report through origin. Whether the cloud session's own
# GitHub connection can reach the repository is only provable by creating the
# session, so that failure surfaces from fm_cloud_create or, when the session
# starts but cannot push, from the bridge's silence report.
fm_cloud_preflight() {  # <git-dir>
  local dir=$1 claude_bin=${FM_CLOUD_CLAUDE:-claude} auth method slug push private
  command -v "$claude_bin" >/dev/null 2>&1 || {
    echo "error: claude-cloud needs the Claude Code CLI ('claude') on PATH" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: claude-cloud needs jq to read the Claude Code login state" >&2
    return 1
  }
  auth=$("$claude_bin" auth status 2>/dev/null) || auth=
  if [ "$(printf '%s' "$auth" | jq -r '.loggedIn // false' 2>/dev/null)" != true ]; then
    echo "error: claude-cloud needs a Claude Code login; run 'claude auth login' with the subscription account" >&2
    return 1
  fi
  method=$(printf '%s' "$auth" | jq -r '.authMethod // "unknown"' 2>/dev/null)
  if [ "$method" != claude.ai ]; then
    echo "error: claude-cloud needs a claude.ai subscription login (cloud sessions are a subscription feature); the current Claude Code login is '$method'" >&2
    return 1
  fi
  slug=$(fm_cloud_origin_slug "$dir") || {
    echo "error: claude-cloud needs the project's origin on github.com, the only forge a cloud session can push to; origin is '$(git -C "$dir" config --get remote.origin.url 2>/dev/null || echo none)'" >&2
    return 1
  }
  command -v gh >/dev/null 2>&1 || {
    echo "error: claude-cloud needs gh to confirm push access to $slug" >&2
    return 1
  }
  push=$(gh api "repos/$slug" --jq '.permissions.push' 2>/dev/null) || push=
  [ "$push" = true ] || {
    echo "error: claude-cloud needs push access to github.com/$slug for the local gh login, which delivers the branch the cloud session pushes; gh reports push=${push:-unreadable}" >&2
    return 1
  }
  private=$(gh api "repos/$slug" --jq '.private' 2>/dev/null) || private=
  [ "$private" = true ] || {
    echo "error: claude-cloud needs github.com/$slug to be a private repository, because the task's status lines, steering record names, and scout report travel through branches on origin; gh reports private=${private:-unreadable}" >&2
    return 1
  }
}

# The instructions a cloud session receives: this runtime contract, the cloud
# helper with the task's return branch and this incarnation's status log baked
# in, then the ordinary launch brief.
fm_cloud_render_prompt() {  # <task-id> <spawn-gen> <kind> <mode> <branch> <base> <slug> <launch-brief> <code-root>
  local id=$1 gen=$2 kind=$3 mode=$4 branch=$5 base=$6 slug=$7 brief=$8 root=$9
  local status_branch status_log
  status_branch=$(fm_cloud_status_branch "$id")
  status_log=$(fm_cloud_status_log "$gen")
  cat <<EOF
# Cloud runtime contract
You are a Firstmate task worker running in a Claude Code cloud session on github.com/$slug, not on the operator's machine.
This section overrides every later instruction that names a local path, a local tool, or the local delivery pipeline, and nothing else.
The firstmate home, every state, data, steering-inbox, and status path named below, the local worktree path, the no-mistakes pipeline, and the operator's local files, databases, containers, and credentials do not exist here; never wait for them or report them missing. This session's own machine has its own toolchains, Docker, PostgreSQL, and Redis, which you may start and use.

- Setup: this session's own disposable clone satisfies the isolation check, so skip the path comparison and the no-mistakes doctor and init steps.
- Channel helper: before anything else, save the script between the helper markers below as an executable named \`fm-cloud\` on PATH (for example \`/usr/local/bin/fm-cloud\`) and run it from the repository checkout. It already knows this task's return branch and never touches your working tree or branch. Then report \`working [at=<epoch>]: cloud session started\` with it, because a session that stays silent is reported as failed to start.
- Status: wherever the instructions say to append a line to the status file, run \`fm-cloud status '<that exact line>'\` instead, keeping the \`{state} [at=<epoch>]: {one short line}\` shape and the same sparing cadence.
- Steering: firstmate's steering arrives as ordinary messages in this session that begin \`Firstmate steering record <name>\`. They are first-party task instructions, exactly like the local inbox records the instructions below describe. Act on each, then run \`fm-cloud ack <name>\`; this replaces every local inbox instruction below.
- Lifecycle requests: a message beginning \`FIRSTMATE CONTROL\` is from firstmate. \`interrupt\` means stop the current step at the next safe point, commit and push work in progress, report \`paused:\`, and wait. \`exit\` means commit and push work in progress, report \`paused: exiting on firstmate request\`, and end your turn without starting new work.
- Waiting: wherever the instructions say to stop and wait for firstmate, end your turn; firstmate's next message wakes you.
- Missing capabilities: when the task needs data, a service, or a credential that exists only on the operator's machine, report \`blocked:\` naming what is missing instead of improvising around it.
EOF
  if [ "$kind" = scout ]; then
    cat <<'EOF'
- Report: write the report in a file outside the repository and publish it with `fm-cloud report <file>` before reporting done, republishing after every revision; this replaces the local report path below. Never commit or push to the repository.
EOF
  else
    cat <<EOF
- Branch: commit on the task branch \`$branch\`, ignoring the branch this session started on. Fetch origin; when \`origin/$branch\` exists, check it out and continue on it, keeping its commits, and otherwise create \`$branch\` from \`origin/$base\`. Push with \`git push -u origin $branch\` after each meaningful commit and always before reporting.
- Delivery: never run no-mistakes, open a pull request, merge, or push to \`$base\`. When the work is complete, committed, and pushed, report \`done [at=<epoch>]: pushed $branch at <full commit sha>: <summary>\`. Firstmate then fetches that branch and runs this task's delivery path (mode=$mode) on the operator's machine; any follow-up instructions arrive as steering messages.
EOF
  fi
  printf '\n--- fm-cloud helper begin ---\n'
  sed -n '1p' "$root/bin/fm-cloud-worker.sh"
  # shellcheck disable=SC2016 # the default expands in the cloud, not here
  printf ': "${FM_CLOUD_STATUS_BRANCH:=%s}"\n: "${FM_CLOUD_STATUS_LOG:=%s}"\nexport FM_CLOUD_STATUS_BRANCH FM_CLOUD_STATUS_LOG\n' "$status_branch" "$status_log"
  sed '1d' "$root/bin/fm-cloud-worker.sh"
  printf -- '--- fm-cloud helper end ---\n\n'
  cat "$brief"
}

# The environment-selection arguments for a cloud session of <project>, from
# the home's optional config/cloud-environment (docs/cloud-workers.md owns the
# format). Each non-comment line is `<project-name|*> <environment-id>`; the
# project's own line wins over `*`, and no match means the CLI's own default
# environment. An Anthropic-hosted `env_` id is selected through the
# remote.defaultEnvironmentId setting for this invocation only, and a
# self-hosted `ccpool_` id through --environment, the two selectors the CLI
# documents. Prints one argument per line; a malformed file fails naming the
# line, so a misconfigured environment never silently becomes the default.
fm_cloud_environment_args() {  # <config-dir> <project-name>
  local file="$1/cloud-environment" project=$2 line key id extra n=0 chosen='' fallback=''
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || {
    echo "error: $file is not a readable file" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    read -r key id extra <<< "$line"
    [ -n "${key:-}" ] || continue
    if [ -z "${id:-}" ] || [ -n "${extra:-}" ]; then
      echo "error: $file line $n must be '<project-name|*> <environment-id>'" >&2
      return 1
    fi
    case "$id" in
      env_[A-Za-z0-9]*|ccpool_[A-Za-z0-9]*) ;;
      *)
        echo "error: $file line $n names '$id', which is neither an Anthropic-hosted env_ id nor a self-hosted ccpool_ id" >&2
        return 1
        ;;
    esac
    case "$id" in *[!A-Za-z0-9_-]*)
      echo "error: $file line $n has an environment id with characters outside letters, digits, '_' and '-'" >&2
      return 1
      ;;
    esac
    if [ "$key" = "$project" ]; then
      chosen=$id
    elif [ "$key" = '*' ]; then
      fallback=$id
    fi
  done < "$file"
  [ -n "$chosen" ] || chosen=$fallback
  case "$chosen" in
    '') ;;
    env_*) printf '%s\n%s\n' --settings "{\"remote\":{\"defaultEnvironmentId\":\"$chosen\"}}" ;;
    ccpool_*) printf '%s\n%s\n' --environment "$chosen" ;;
  esac
}

# Parse the creation transcript `claude --cloud <prompt>` prints. Prints
# "<session-id>\t<url>"; nonzero when either is absent. The CLI writes the URL
# as `View: https://claude.ai/code/<session-id>?...` (verified, Claude Code
# 2.1.312); the query string is presentation only and is dropped.
fm_cloud_parse_create() {  # <transcript-file>
  local plain url id
  plain=$(sed 's/\x1b\[[0-9;?<>=]*[A-Za-z]//g' "$1" | tr -d '\r')
  url=$(printf '%s\n' "$plain" | sed -n 's#.*View: \(https://claude\.ai/code/[A-Za-z0-9_-]*\).*#\1#p' | head -n 1)
  [ -n "$url" ] || return 1
  id=${url##*/}
  case "$id" in session_*|cse_*) ;; *) return 1 ;; esac
  printf '%s\t%s' "$id" "$url"
}

# Create the cloud session from <prompt-file> with <dir> as the repository
# context, passing any environment-selection arguments after <log>. The CLI
# renders terminal output and exits once the session exists, so it runs under
# a pseudo-terminal and its transcript is kept in <log>. It starts like an
# interactive session, so a folder it has never been told to trust stops on
# Claude's workspace-trust dialog: the spawn pre-registers trust for the task
# worktree first (bin/fm-claude-trust.sh), and a creation still waiting after
# FM_CLOUD_CREATE_TIMEOUT seconds (default 120) is stopped and reported with
# the last lines it rendered rather than left hanging.
# Prints "<session-id>\t<url>".
fm_cloud_create() {  # <dir> <prompt-file> <log> [cli-arg...]
  local dir=$1 prompt_file=$2 log=$3 claude_bin=${FM_CLOUD_CLAUDE:-claude}
  local limit=${FM_CLOUD_CREATE_TIMEOUT:-120} wrapper pid waited=0 status=0 children
  shift 3
  : > "$log" || return 1
  if [ "$(uname -s)" = Darwin ]; then
    (cd "$dir" && exec script -q -F "$log" "$claude_bin" "$@" --cloud "$(cat "$prompt_file")" </dev/null >/dev/null 2>&1) &
    pid=$!
  else
    # util-linux script takes the command as one shell string, so the exact
    # argument vector goes through a private bash wrapper instead.
    wrapper=$(mktemp "${TMPDIR:-/tmp}/fm-cloud-create.XXXXXX") || return 1
    # shellcheck disable=SC2016 # the prompt is read when the wrapper runs
    { printf '#!/usr/bin/env bash\nexec'; printf ' %q' "$claude_bin" "$@" --cloud; printf ' "$(cat %q)"\n' "$prompt_file"; } > "$wrapper"
    (cd "$dir" && exec script -q -e -f -c "bash $(printf '%q' "$wrapper")" "$log" </dev/null >/dev/null 2>&1) &
    pid=$!
  fi
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      children=$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')
      # shellcheck disable=SC2086 # one argument per child pid
      kill $children "$pid" 2>/dev/null || true
      status=timeout
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$status" != timeout ]; then
    wait "$pid" || status=$?
  fi
  [ -z "${wrapper:-}" ] || rm -f "$wrapper"
  fm_cloud_parse_create "$log" && return 0
  echo "error: 'claude --cloud' did not report a created session ($( [ "$status" = timeout ] && echo "still waiting after ${limit}s, stopped" || echo "exit $status" )); its last output: $(sed 's/\x1b\[[0-9;?<>=]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g' "$log" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 6 | tr '\n' ' ')" >&2
  return 1
}

# Queue <message> into cloud session <session-id>. Succeeds only on the CLI's
# typed {ok: true} result. A session the service reports archived or missing
# prints `gone` on stdout and returns 2, because no later message can reach it
# either; any other failure returns 1 and is worth retrying.
fm_cloud_send() {  # <session-id> <message>
  local claude_bin=${FM_CLOUD_CLAUDE:-claude} out error
  out=$(printf '%s' "$2" | "$claude_bin" -p --cloud "$1" --output-format json 2>&1) || true
  if [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
    return 0
  fi
  error=$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null) || error=
  [ -n "$error" ] || error=$out
  case "$error" in
    *archived*|*'Session not found'*)
      printf 'gone'
      return 2
      ;;
  esac
  printf '%s' "$error" | tr '\n' ' ' >&2
  return 1
}

# The lifecycle request texts the cloud contract above defines.
fm_cloud_control_text() {  # <interrupt|exit|closed>
  case "$1" in
    interrupt) printf '%s' 'FIRSTMATE CONTROL interrupt: stop the current step at the next safe point, commit and push work in progress, report paused:, and wait for instructions.' ;;
    exit) printf '%s' 'FIRSTMATE CONTROL exit: commit and push work in progress, report paused: exiting on firstmate request, and end your turn without starting new work.' ;;
    closed) printf '%s' 'FIRSTMATE CONTROL exit: firstmate has finished with this task and closed its channel. Do no further work, report nothing, and end your turn.' ;;
    *) return 1 ;;
  esac
}

# Send lifecycle request <verb> to <session-id>. A session already gone counts
# as delivered, because it can do no further work either way.
fm_cloud_control() {  # <session-id> <interrupt|exit|closed>
  local text status=0
  text=$(fm_cloud_control_text "$2") || return 1
  fm_cloud_send "$1" "$text" >/dev/null || status=$?
  [ "$status" = 2 ] && return 0
  return "$status"
}

# Remove the return branch from origin and its local tracking ref. A branch
# origin reports absent is not an error, so cleanup is idempotent; a query that
# fails proves nothing and fails.
fm_cloud_delete_channel() {  # <task-id> <git-dir>
  local branch status=0
  branch=$(fm_cloud_status_branch "$1")
  GIT_TERMINAL_PROMPT=0 git -C "$2" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) GIT_TERMINAL_PROMPT=0 git -C "$2" push -q origin --delete "$branch" 2>/dev/null || return 1 ;;
    2) ;;
    *) return 1 ;;
  esac
  git -C "$2" update-ref -d "refs/fm-cloud/$1/status" 2>/dev/null || true
}
