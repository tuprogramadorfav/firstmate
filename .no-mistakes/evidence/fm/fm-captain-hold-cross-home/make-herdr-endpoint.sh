#!/usr/bin/env bash
# Give a lab task a real Herdr endpoint the way bin/fm-spawn.sh's herdr arm
# does (fm_backend_herdr_container_ensure + fm_backend_herdr_create_task), in
# the named fm-lab-* session only, and print the meta lines spawn records.
# Usage: HERDR_SESSION=fm-lab-... make-herdr-endpoint.sh <code-root> <home> <task-id>
set -u
CODE=$1 HOME_DIR=$2 ID=$3
case "${HERDR_SESSION:-}" in
  fm-lab-*) ;;
  *) echo "refusing: HERDR_SESSION must name an fm-lab-* session" >&2; exit 2 ;;
esac
export FM_HOME=$HOME_DIR
# shellcheck disable=SC1091
. "$CODE/bin/fm-backend.sh"
fm_backend_source herdr || exit 1
raw=$(fm_backend_herdr_container_ensure "$HOME_DIR" launcher-home "$HERDR_SESSION") || exit 1
container=${raw%%$'\t'*}
seeded=${raw#*$'\t'}
ids=$(fm_backend_herdr_create_task "$container" "fm-$ID" "$HOME_DIR" "$seeded") || exit 1
tab=${ids%% *}
pane=${ids#* }
printf 'window=%s:%s\n' "$HERDR_SESSION" "$pane"
printf 'backend=herdr\n'
printf 'herdr_session=%s\n' "$HERDR_SESSION"
printf 'herdr_workspace_id=%s\n' "${container#*:}"
printf 'herdr_tab_id=%s\n' "$tab"
printf 'herdr_pane_id=%s\n' "$pane"
