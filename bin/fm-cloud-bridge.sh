#!/usr/bin/env bash
# fm-cloud-bridge.sh - the local endpoint program of a claude-cloud task.
#
# Usage: fm-cloud-bridge.sh <state-dir> <data-dir> <config-dir> <task-id>
#
# bin/fm-spawn.sh creates the task's Claude Code cloud session, records it in
# state/<id>.meta (cloud_session=, cloud_url=), and launches this program in
# the task's ordinary local endpoint, which keeps every existing runtime
# contract working: the endpoint is peekable, it has a recovery-grade agent
# identity (this program re-executes itself under the anchored process name
# `fm-cloud-bridge`, which bin/fm-agent-process-lib.sh recognizes), and the
# control plane's keys reach it. The bridge relays the task channels between
# this home and the session (bin/fm-cloud-lib.sh), polling every
# FM_CLOUD_POLL_SECS (default 30) and immediately after any Enter typed into it:
#
#   steering  every unhandled state/<id>.inbox/NNN.msg is sent once into the
#             session as a message naming the record, and moved into handled/
#             only when the cloud worker acknowledges it on the return branch,
#             so the inbox's re-ring and escalation ladder
#             (bin/fm-task-inbox-lib.sh) still measures the worker.
#   status    each new line of this incarnation's status log (the task
#             record's spawn_gen, bin/fm-cloud-lib.sh) on the return branch is appended
#             verbatim to state/<id>.status (with the fleet-ledger hook the
#             brief's own append runs), so it wakes firstmate and classifies
#             exactly as a local worker's line. A ship's `done:` line is
#             relayed only after the pushed task branch is fetched and
#             fast-forwarded into the local copy, so the delivery path that
#             follows runs locally on the exact pushed head; when that is
#             impossible a `blocked:` line naming the reason is relayed instead.
#   busy      a relayed `working:` or `resolved:` line marks the task busy and
#             any other state marks it idle (source cloud-bridge,
#             bin/fm-busy-lib.sh), closing the turn for the watcher.
#   report    a scout's published report.md is copied to data/<id>/report.md.
#   silence   a session that writes no status line of its own within
#             FM_CLOUD_FIRST_STATUS_SECS (default 900) of launch gets one
#             `blocked:` line, because
#             repository access or session startup most likely failed.
#
# Keys (bin/fm-control-lib.sh owns which verb sends which): Escape sends the
# session an interrupt request; Ctrl-C sends it an exit request and ends this
# program. Both are ordinary messages the cloud worker reads at its next turn
# boundary, because the CLI cannot cancel a cloud turn. Any other typed text,
# such as the inbox doorbell, only triggers an immediate sync. The screen ends
# with an empty `❯ ` composer row because nothing typed here is ever kept as
# pending input.
#
# Durable relay progress lives in state/<id>.cloud-sync (relayed line count,
# sent steering records, last relayed report blob, the session it belongs to,
# and the session sent an exit), so a restarted bridge resumes where the
# previous one stopped instead of relaying or sending anything twice.

if [ "${FM_CLOUD_BRIDGE_NAMED:-}" != 1 ]; then
  FM_CLOUD_BRIDGE_NAMED=1 exec -a fm-cloud-bridge bash "$0" "$@"
fi
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 4 ] || {
  echo "usage: fm-cloud-bridge.sh <state-dir> <data-dir> <config-dir> <task-id>" >&2
  exit 2
}
STATE=$1
DATA=$2
CONFIG=$3
ID=$4
export FM_ROOT=${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}
export FM_HOME=${FM_HOME:-$FM_ROOT}

# shellcheck source=bin/fm-cloud-lib.sh
. "$SCRIPT_DIR/fm-cloud-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"

META="$STATE/$ID.meta"
SYNC="$STATE/$ID.cloud-sync"
INBOX="$STATE/$ID.inbox"
POLL=${FM_CLOUD_POLL_SECS:-30}
FIRST_STATUS_SECS=${FM_CLOUD_FIRST_STATUS_SECS:-900}

WT=$(fm_meta_get "$META" worktree)
KIND=$(fm_meta_get "$META" kind)
BRANCH=$(fm_meta_get "$META" branch)
SESSION=$(fm_meta_get "$META" cloud_session)
URL=$(fm_meta_get "$META" cloud_url)
BUSY_GEN=$(fm_meta_get "$META" busy_gen)
SPAWN_GEN=$(fm_meta_get "$META" spawn_gen)
STATUS_BRANCH=$(fm_cloud_status_branch "$ID")
STATUS_LOG=$(fm_cloud_status_log "$SPAWN_GEN")
STATUS_REF="refs/fm-cloud/$ID/status"

if [ -z "$WT" ] || [ ! -d "$WT" ] || [ -z "$SESSION" ] || [ -z "$SPAWN_GEN" ]; then
  echo "error: task $ID records no cloud session or worktree in $META; launch it through fm-spawn.sh --harness claude-cloud" >&2
  exit 1
fi

sync_get() {  # <key>
  fm_meta_get "$SYNC" "$1"
}

sync_set() {  # <key> <value>
  local tmp
  tmp=$(mktemp "$STATE/.$ID.cloud-sync.XXXXXX") || return 1
  if { [ ! -f "$SYNC" ] || grep -v "^$1=" "$SYNC"; printf '%s=%s\n' "$1" "$2"; } > "$tmp" \
    && mv -f "$tmp" "$SYNC"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# A new session (a relaunch) writes a status log of its own on the same return
# branch, so its relayed count and silence clock start fresh and records it has
# not been sent are sent to it.
if [ "$(sync_get session)" != "$SESSION" ]; then
  sync_set session "$SESSION"
  sync_set relayed 0
  sync_set started "$(date +%s)"
  sync_set silence_reported ""
  sync_set sent ""
fi

NOTE=
LAST_ACTIVITY=
LAST_LINE=
EXIT_REQUESTED=0
trap 'EXIT_REQUESTED=1' INT
# How long the bytes of an escape sequence may trail its Escape. Bash 3.2's
# read accepts only whole seconds.
ESC_WAIT=1
[ "${BASH_VERSINFO[0]}" -lt 4 ] || ESC_WAIT=0.05

append_status() {  # <line>
  printf '%s\n' "$1" >> "$STATE/$ID.status" || return 1
  if [ -e "$CONFIG/fleet-ledger" ]; then
    "$FM_ROOT/bin/fm-fleet-ledger.sh" appended "$CONFIG" "$STATE/$ID.status" >/dev/null 2>&1 || true
  fi
}

mark_busy() {  # <busy|idle> <event>
  [ -n "$BUSY_GEN" ] || return 0
  set -- "$1" --gen "$BUSY_GEN" --source cloud-bridge --event "$2"
  [ "$1" = idle ] && set -- "$@" --turn-ended
  "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" "$@" >/dev/null 2>&1 || true
}

# Fast-forward the local copy onto the pushed task branch. Prints the reason
# and fails when that cannot be done without touching local work.
sync_worktree() {
  local remote cur
  GIT_TERMINAL_PROMPT=0 git -C "$WT" fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || {
    printf 'branch %s is not on origin' "$BRANCH"
    return 1
  }
  remote=$(git -C "$WT" rev-parse "refs/remotes/origin/$BRANCH") || return 1
  if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    printf 'the local copy %s has uncommitted changes' "$WT"
    return 1
  fi
  if git -C "$WT" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
    cur=$(git -C "$WT" rev-parse "refs/heads/$BRANCH")
    git -C "$WT" merge-base --is-ancestor "$cur" "$remote" || {
      printf 'local branch %s has commits that are not on origin/%s' "$BRANCH" "$BRANCH"
      return 1
    }
    if ! git -C "$WT" checkout -q "$BRANCH" 2>/dev/null \
      || ! git -C "$WT" merge -q --ff-only "$remote" 2>/dev/null; then
      printf 'could not fast-forward %s in %s' "$BRANCH" "$WT"
      return 1
    fi
  else
    git -C "$WT" checkout -q -b "$BRANCH" "$remote" 2>/dev/null || {
      printf 'could not check out %s in %s' "$BRANCH" "$WT"
      return 1
    }
  fi
  git -C "$WT" branch -q --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
  printf '%s' "$remote"
}

relay_line() {  # <line>
  local line=$1 state reason
  if ! printf '%s\n' "$line" | grep -Eq '^[a-z][a-z-]*( \[[^]]*\])*:'; then
    NOTE="ignored a malformed status line from the cloud: ${line:0:80}"
    return 0
  fi
  state=${line%%[ :]*}
  if [ "$state" = "done" ] && [ "$KIND" = ship ]; then
    if ! reason=$(sync_worktree); then
      line="blocked [at=$(date +%s)]: cloud worker reported done, but $reason; its report was: ${line#*: }"
      state=blocked
    fi
  fi
  append_status "$line" || {
    NOTE="could not append to $STATE/$ID.status"
    return 1
  }
  LAST_LINE=$line
  case "$state" in
    working|resolved) mark_busy busy "cloud-$state" ;;
    *) mark_busy idle "cloud-$state" ;;
  esac
}

# Send each unhandled steering record that this session has not received yet.
forward_inbox() {
  local f name sent body status
  [ -d "$INBOX" ] || return 0
  for f in "$INBOX"/[0-9]*.msg; do
    [ -f "$f" ] || continue
    name="inbox/${f##*/}"
    sent=" $(sync_get sent) "
    case "$sent" in *" $name "*) continue ;; esac
    # The record body follows the header's `--` separator
    # (bin/fm-task-inbox-lib.sh owns the format).
    body=$(sed '1,/^--$/d' "$f")
    status=0
    fm_cloud_send "$SESSION" "Firstmate steering record $name - act on it, then run \`fm-cloud ack $name\`:

$body" >/dev/null || status=$?
    case "$status" in
      0)
        sync_set sent "$(sync_get sent) $name"
        NOTE="sent $name to the cloud session"
        ;;
      2)
        NOTE="the cloud session is archived or gone; $name cannot be delivered"
        return 1
        ;;
      *)
        NOTE="could not send $name to the cloud session; retrying next poll"
        return 1
        ;;
    esac
  done
}

pull_status() {
  local head seen log total relayed i line acks name report_blob
  GIT_TERMINAL_PROMPT=0 git -C "$WT" fetch -q origin "+refs/heads/$STATUS_BRANCH:$STATUS_REF" 2>/dev/null || return 0
  head=$(git -C "$WT" rev-parse "$STATUS_REF") || return 0
  LAST_ACTIVITY=$(git -C "$WT" log -1 --format=%ct "$STATUS_REF" 2>/dev/null)
  seen=$(sync_get status_head)
  [ "$head" != "$seen" ] || return 0
  log=$(git -C "$WT" show "$head:$STATUS_LOG" 2>/dev/null) || log=
  total=0
  [ -z "$log" ] || total=$(printf '%s\n' "$log" | wc -l | tr -d ' ')
  relayed=$(sync_get relayed)
  relayed=${relayed:-0}
  i=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$((i + 1))
    [ "$i" -gt "$relayed" ] || continue
    relay_line "$line" || return 1
    sync_set relayed "$i" || return 1
  done <<EOF
$log
EOF
  [ "$total" -ge "$relayed" ] || NOTE="the cloud status log shrank; nothing was relayed twice"
  acks=$(git -C "$WT" show "$head:acks" 2>/dev/null) || acks=
  while IFS= read -r name; do
    case "$name" in
      inbox/[0-9]*.msg)
        if [ -f "$INBOX/${name#inbox/}" ]; then
          mkdir -p "$INBOX/handled" && mv -f "$INBOX/${name#inbox/}" "$INBOX/handled/" || true
        fi
        ;;
    esac
  done <<EOF
$acks
EOF
  if [ "$KIND" = scout ]; then
    report_blob=$(git -C "$WT" rev-parse -q --verify "$head:report.md" 2>/dev/null) || report_blob=
    if [ -n "$report_blob" ] && [ "$report_blob" != "$(sync_get report_blob)" ]; then
      mkdir -p "$DATA/$ID" \
        && git -C "$WT" cat-file blob "$report_blob" > "$DATA/$ID/.report.md.cloud" \
        && mv -f "$DATA/$ID/.report.md.cloud" "$DATA/$ID/report.md" \
        && sync_set report_blob "$report_blob" \
        && NOTE="copied the cloud report to $DATA/$ID/report.md"
    fi
  fi
  sync_set status_head "$head"
}

# Only a status line this session wrote proves it started; other commits on
# the return branch, such as a superseded session's exit line, do not.
check_silence() {
  local started relayed now
  [ -z "$(sync_get silence_reported)" ] || return 0
  relayed=$(sync_get relayed)
  [ "${relayed:-0}" -eq 0 ] || return 0
  started=$(sync_get started)
  now=$(date +%s)
  [ -n "$started" ] && [ $((now - started)) -ge "$FIRST_STATUS_SECS" ] || return 0
  append_status "blocked [at=$now]: cloud session $URL has not reported within $((FIRST_STATUS_SECS / 60)) minutes of launch; open it to check repository access and startup" || return 0
  sync_set silence_reported "$now"
  mark_busy idle cloud-silent
}

SCREEN=
render() {
  local pending=0 age='none yet' body f
  if [ -d "$INBOX" ]; then
    for f in "$INBOX"/[0-9]*.msg; do
      [ -f "$f" ] && pending=$((pending + 1))
    done
  fi
  [ -z "$LAST_ACTIVITY" ] || age="$(date -r "$LAST_ACTIVITY" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$LAST_ACTIVITY" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  body=$(
    printf 'fm-cloud-bridge  task %s (%s)\n' "$ID" "$KIND"
    printf 'cloud session    %s\n' "$URL"
    printf 'return branch    origin %s\n' "$STATUS_BRANCH"
    printf 'last activity    %s\n' "$age"
    printf 'last status      %s\n' "${LAST_LINE:-$(tail -n 1 "$STATE/$ID.status" 2>/dev/null)}"
    printf 'steering         %s record(s) awaiting acknowledgement\n' "$pending"
    [ -z "$NOTE" ] || printf 'note             %s\n' "$NOTE"
    printf '\nEscape sends an interrupt request; Ctrl-C sends an exit request and stops this bridge.\n'
  )
  [ "$body" != "$SCREEN" ] || return 0
  SCREEN=$body
  printf '\033[H\033[2J%s\n\n\xe2\x9d\xaf ' "$body"
}

sync_once() {
  forward_inbox || true
  pull_status || true
  check_silence || true
  render
}

request_exit() {
  if fm_cloud_control "$SESSION" exit; then
    sync_set ended_session "$SESSION"
    printf '\nexit request sent to cloud session %s\n' "$URL"
    exit 0
  fi
  append_status "blocked [at=$(date +%s)]: the exit request could not reach cloud session $URL; stop it from claude.ai/code" || true
  printf '\nexit request could NOT be delivered to %s\n' "$URL"
  exit 1
}

render
while :; do
  sync_once
  [ "$EXIT_REQUESTED" = 0 ] || request_exit
  key=
  while :; do
    if IFS= read -r -s -n 1 -t "$POLL" key; then
      if [ "$key" = $'\e' ]; then
        # A lone Escape is the interrupt key; an escape sequence (arrow keys
        # and the like) arrives with more bytes right behind it.
        if IFS= read -r -s -n 1 -t "$ESC_WAIT" _; then
          while IFS= read -r -s -n 1 -t "$ESC_WAIT" _; do :; done
          continue
        fi
        if fm_cloud_control "$SESSION" interrupt; then
          NOTE="interrupt request sent to the cloud session"
        else
          NOTE="the interrupt request could not be sent; press Escape again"
        fi
        break
      fi
      [ -n "$key" ] || break
      continue
    fi
    break
  done
  [ "$EXIT_REQUESTED" = 0 ] || request_exit
done
