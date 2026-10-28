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

# Read one file from the status branch, empty when absent.
status_file() {  # <path>
  local head
  head=$(status_head)
  [ -n "$head" ] || return 0
  git show "$head:$1" 2>/dev/null || true
}

# Commit <path> with <content-file> onto the status branch and push it. One
# writer means a rejected push is transient, so it is retried rather than merged.
status_commit() {  # <path> <content-file> <message>
  local path=$1 file=$2 msg=$3 parent blob tree commit idx try
  parent=$(status_head)
  idx=$(mktemp)
  rm -f "$idx"
  if [ -n "$parent" ]; then
    GIT_INDEX_FILE=$idx git read-tree "$parent"
  else
    GIT_INDEX_FILE=$idx git read-tree --empty
  fi
  blob=$(git hash-object -w -- "$file")
  GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,$path"
  tree=$(GIT_INDEX_FILE=$idx git write-tree)
  rm -f "$idx"
  if [ -n "$parent" ]; then
    commit=$(git -c user.name=fm-cloud -c user.email=fm-cloud@localhost commit-tree "$tree" -p "$parent" -m "$msg")
  else
    commit=$(git -c user.name=fm-cloud -c user.email=fm-cloud@localhost commit-tree "$tree" -m "$msg")
  fi
  for try in 1 2 3 4 5; do
    if git push -q "$REMOTE" "$commit:refs/heads/$STATUS_BRANCH" 2>/dev/null; then
      git update-ref "$STATUS_REF" "$commit"
      return 0
    fi
    sleep "$try"
  done
  die "could not push $path to $REMOTE $STATUS_BRANCH"
}

cmd_status() {
  local line=$* tmp
  [ -n "$line" ] || die "status needs a line"
  case "$line" in *$'\n'*) die "status takes exactly one line" ;; esac
  tmp=$(mktemp)
  status_file status.log > "$tmp"
  printf '%s\n' "$line" >> "$tmp"
  status_commit status.log "$tmp" "status: ${line%%:*}"
  rm -f "$tmp"
}

cmd_ack() {
  local tmp name
  [ "$#" -gt 0 ] || die "ack needs at least one record name"
  tmp=$(mktemp)
  status_file acks > "$tmp"
  for name in "$@"; do
    grep -qxF -- "$name" "$tmp" || printf '%s\n' "$name" >> "$tmp"
  done
  status_commit acks "$tmp" "ack: $*"
  rm -f "$tmp"
}

cmd_report() {
  [ -f "${1:-}" ] || die "report needs a readable file"
  status_commit report.md "$1" "report"
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  ack) shift; cmd_ack "$@" ;;
  report) shift; cmd_report "$@" ;;
  *) die "usage: fm-cloud status <line> | ack <name>... | report <file>" ;;
esac
