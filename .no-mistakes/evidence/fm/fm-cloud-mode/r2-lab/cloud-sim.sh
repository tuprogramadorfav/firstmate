#!/usr/bin/env bash
# Scripted stand-in for the Claude Code cloud service, used as FM_CLOUD_CLAUDE.
# `auth status` is answered by the machine's real claude login (read-only).
# `--cloud <prompt>` prints the real CLI's creation transcript and starts a
# simulated cloud VM that follows the rendered contract mechanically using the
# real fm-cloud helper extracted from the prompt. `-p --cloud <id>` queues a
# message into that session. SIM_DIR holds every session's files.
set -u
SIM=${SIM_DIR:?}
REAL_CLAUDE=/Users/programanding/.local/bin/claude
mkdir -p "$SIM"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$SIM/service.log"; }

if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exec env -u CLAUDE_CONFIG_DIR -u HOME HOME=/Users/programanding "$REAL_CLAUDE" auth status
fi

turn() {  # <session> <kind:start|msg> <message-file>
  local s=$1 k=$2 f=$3 vm="$SIM/$1/vm" bin="$SIM/$1/bin" now branch base sha name
  until mkdir "$SIM/$s/lock" 2>/dev/null; do sleep 0.2; done
  export PATH="$bin:$PATH"
  now() { date +%s; }
  branch=$(cat "$SIM/$s/branch" 2>/dev/null)
  base=$(cat "$SIM/$s/base" 2>/dev/null)
  if [ "$k" = start ]; then
    git clone -q https://github.com/tuprogramadorfav/cproj-lab "$vm"
    mkdir -p "$bin"
    sed -n '/^--- fm-cloud helper begin ---$/,/^--- fm-cloud helper end ---$/p' "$SIM/$s/prompt" | sed '1d;$d' > "$bin/fm-cloud"
    chmod +x "$bin/fm-cloud"
    cd "$vm" || exit 1
    sleep 2
    fm-cloud status "working [at=$(now)]: cloud session started"
    sleep 3
    if [ -n "$branch" ]; then
      git fetch -q origin
      if git rev-parse -q --verify "origin/$branch" >/dev/null; then git checkout -q -B "$branch" "origin/$branch"; else git checkout -q -b "$branch" "origin/$base"; fi
      echo "change from $s" >> CHANGES.md
      git add CHANGES.md && git commit -qm "cloud: add CHANGES.md ($s)"
      git push -q -u origin "$branch"
      sha=$(git rev-parse HEAD)
      fm-cloud status "done [at=$(now)]: pushed $branch at $sha: added CHANGES.md"
    else
      printf '# Scout report\n\nThe README contains a single heading, `# cproj-lab`.\n' > "$SIM/$s/report.md"
      fm-cloud report "$SIM/$s/report.md"
      fm-cloud status "done [at=$(now)]: report published"
    fi
  else
    cd "$vm" || exit 1
    local msg; msg=$(cat "$f")
    case "$msg" in
      "FIRSTMATE CONTROL interrupt"*) fm-cloud status "paused [at=$(now)]: interrupted on firstmate request; nothing in progress" ;;
      "FIRSTMATE CONTROL exit: firstmate has finished"*) : ;;
      "FIRSTMATE CONTROL exit"*) fm-cloud status "paused [at=$(now)]: exiting on firstmate request" ;;
      "Firstmate steering record "*)
        name=${msg#Firstmate steering record }; name=${name%%[[:space:]:]*}
        fm-cloud status "working [at=$(now)]: acting on steering $name"
        if [ -n "$branch" ]; then
          echo "follow-up $name" >> CHANGES.md
          git add CHANGES.md && git commit -qm "cloud: follow-up $name"
          git push -q origin "$branch"
          fm-cloud ack "$name"
          fm-cloud status "done [at=$(now)]: pushed $branch at $(git rev-parse HEAD): follow-up $name"
        else
          fm-cloud ack "$name"
          fm-cloud status "done [at=$(now)]: report published"
        fi
        ;;
    esac
  fi
  rmdir "$SIM/$s/lock"
}

detach() {  # <session> <kind> <file>: run a turn outside the caller's session and pty
  nohup perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV' "$0" __turn "$@" </dev/null >>"$SIM/$1/vm.log" 2>&1 &
}
if [ "${1:-}" = __turn ]; then shift; turn "$@"; exit; fi

if [ "${1:-}" = -p ] && [ "${2:-}" = --cloud ]; then
  s=$3
  [ -d "$SIM/$s" ] || { printf '{"ok":false,"error":"Session not found"}\n'; exit 1; }
  n=$(ls "$SIM/$s" | grep -c '^msg\.' )
  f="$SIM/$s/msg.$((n + 1))"
  cat > "$f"
  log "message to $s: $(head -c 120 "$f" | tr '\n' ' ')"
  detach "$s" msg "$f"
  printf '{"ok":true,"session_id":"%s","url":"https://claude.ai/code/%s"}\n' "$s" "$s"
  exit 0
fi

prompt=; prev=
for a in "$@"; do [ "$prev" != --cloud ] || prompt=$a; prev=$a; done
if [ -n "$prompt" ]; then
  n=$(cat "$SIM/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$SIM/count"
  s="session_r2lab$n"
  mkdir -p "$SIM/$s"
  printf '%s' "$prompt" > "$SIM/$s/prompt"
  printf '%s\n' "$@" | grep -v -F -x -- "$prompt" > "$SIM/$s/argv"
  printf '%s' "$prompt" | sed -n 's/^- Branch: commit on the task branch `\([^`]*\)`.*/\1/p' > "$SIM/$s/branch"
  printf '%s' "$prompt" | sed -n 's/.*otherwise create `[^`]*` from `origin\/\([^`]*\)`.*/\1/p' > "$SIM/$s/base"
  log "created $s in $PWD branch=$(cat "$SIM/$s/branch")"
  detach "$s" start ""
  sleep 1  # let the detached VM leave the creation pty's process group first
  printf 'Created cloud session: lab %s\r\nView: https://claude.ai/code/%s?from=cli&m=0\r\nResume with: claude --teleport %s\r\n' "$n" "$s" "$s"
  exit 0
fi
exit 1
