#!/usr/bin/env bash
# fm-cloud-worker.sh - the CLOUD side of a claude-cloud task's return channel.
#
# A Claude Code cloud session sees only GitHub: it cannot append to the task's
# local status file, acknowledge its local steering records, or write the scout
# report into firstmate's home. Steering already reaches the session directly
# (bin/fm-cloud-bridge.sh sends each record with `claude -p --cloud`), so this
# helper carries only the way back, on one branch of the project's origin that
# only it writes:
#
#   <status-branch>  status.log  one Firstmate status line per line, in order
#                    acks        one acknowledged steering record name per line
#                    report.md   the scout report, when one is published
#
# bin/fm-cloud-lib.sh owns the branch name and embeds this file verbatim in the
# cloud launch instructions, which tell the cloud worker to install it as an
# executable named `fm-cloud` with FM_CLOUD_STATUS_BRANCH filled in. It never
# touches the working tree or the checked-out branch: commits are built with
# plumbing in a private index and pushed by explicit refspec, so the task
# branch and its uncommitted work are unaffected.
#
# Usage: fm-cloud status <line>     append one status line and push it
#        fm-cloud ack <name>...     acknowledge steering records by name
#        fm-cloud report <file>     publish <file> as the scout report
#
# Tunables: FM_CLOUD_REMOTE (default origin).
set -euo pipefail

STATUS_BRANCH=${FM_CLOUD_STATUS_BRANCH:?FM_CLOUD_STATUS_BRANCH is required}
REMOTE=${FM_CLOUD_REMOTE:-origin}
STATUS_REF=refs/fm-cloud/status

die() {
  printf 'fm-cloud: %s\n' "$*" >&2
  exit 1
}

git rev-parse --git-dir >/dev/null 2>&1 || die "run inside the task's git checkout"

# The status branch's current commit, adopting the remote copy on first use so
# a replacement session continues the same log instead of forking it.
status_head() {
  if git rev-parse -q --verify "$STATUS_REF" >/dev/null; then
    git rev-parse "$STATUS_REF"
    return 0
  fi
  if git fetch -q "$REMOTE" "+refs/heads/$STATUS_BRANCH:$STATUS_REF" 2>/dev/null; then
    git rev-parse "$STATUS_REF"
  fi
}

# Apply <filter> to <path> on the status branch and push the result. The
# filter reads the file's current content (empty when absent) on stdin and
# prints its new content. A rejected push means another writer moved the
# branch (a superseded session's last status line can land after its
# replacement started), so each retry refetches the remote head and reapplies
# the filter on it; every change only appends or replaces, so that is safe.
status_update() {  # <path> <message> <filter> [arg...]
  local path=$1 msg=$2 parent blob tree commit idx tmp try
  shift 2
  for try in 1 2 3 4 5; do
    parent=$(status_head)
    tmp=$(mktemp)
    { [ -z "$parent" ] || git show "$parent:$path" 2>/dev/null || true; } | "$@" > "$tmp"
    idx=$(mktemp)
    rm -f "$idx"
    if [ -n "$parent" ]; then
      GIT_INDEX_FILE=$idx git read-tree "$parent"
    else
      GIT_INDEX_FILE=$idx git read-tree --empty
    fi
    blob=$(git hash-object -w -- "$tmp")
    rm -f "$tmp"
    GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,$path"
    tree=$(GIT_INDEX_FILE=$idx git write-tree)
    rm -f "$idx"
    if [ -n "$parent" ]; then
      commit=$(git -c user.name=fm-cloud -c user.email=fm-cloud@localhost commit-tree "$tree" -p "$parent" -m "$msg")
    else
      commit=$(git -c user.name=fm-cloud -c user.email=fm-cloud@localhost commit-tree "$tree" -m "$msg")
    fi
    if git push -q "$REMOTE" "$commit:refs/heads/$STATUS_BRANCH" 2>/dev/null; then
      git update-ref "$STATUS_REF" "$commit"
      return 0
    fi
    sleep "$try"
    git fetch -q "$REMOTE" "+refs/heads/$STATUS_BRANCH:$STATUS_REF" 2>/dev/null || true
  done
  die "could not push $path to $REMOTE $STATUS_BRANCH"
}

append_line() {  # <line>
  cat
  printf '%s\n' "$1"
}

add_acks() {  # <name>...
  local acks name nl=$'\n'
  acks=$(cat)
  for name in "$@"; do
    case "$nl$acks$nl" in
      *"$nl$name$nl"*) ;;
      *) acks=${acks:+$acks$nl}$name ;;
    esac
  done
  printf '%s\n' "$acks"
}

replace_with() {  # <file>
  cat > /dev/null
  cat -- "$1"
}

cmd_status() {
  local line=$*
  [ -n "$line" ] || die "status needs a line"
  case "$line" in *$'\n'*) die "status takes exactly one line" ;; esac
  status_update status.log "status: ${line%%:*}" append_line "$line"
}

cmd_ack() {
  [ "$#" -gt 0 ] || die "ack needs at least one record name"
  status_update acks "ack: $*" add_acks "$@"
}

cmd_report() {
  [ -f "${1:-}" ] || die "report needs a readable file"
  status_update report.md "report" replace_with "$1"
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  ack) shift; cmd_ack "$@" ;;
  report) shift; cmd_report "$@" ;;
  *) die "usage: fm-cloud status <line> | ack <name>... | report <file>" ;;
esac
