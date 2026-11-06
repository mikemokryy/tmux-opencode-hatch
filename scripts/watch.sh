#!/usr/bin/env bash
# Watch OpenCode's shared service and forward bells for dedicated sessions.
#
# OpenCode has no hook mechanism that a shell-only plugin can register, so this
# polls the local API instead. A status change triggers a bell exactly when a
# turn calls for you:
#
#   -> waiting   a permission request or a question is pending
#   busy -> idle a turn just finished
#
# It also refreshes the picker cache, which is what keeps its first painted frame
# honest. A single instance runs per tmux server; reloads are harmless, and
# `@opencode_watch 'off'` stops the running instance at its next tick.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"
# shellcheck source=api.sh
. "$DIR/api.sh"

command -v jq >/dev/null 2>&1 || exit 0

# One watcher per tmux server: `tmux list-panes` below only sees its own server.
sock="$(tmux display-message -p '#{socket_path}' 2>/dev/null || printf 'default')"
lock="${TMPDIR:-/tmp}/tmux-opencode-hatch-watch-$(id -u)-$(session_hash "$sock")"
if ! mkdir "$lock" 2>/dev/null; then
  lpid="$(cat "$lock/pid" 2>/dev/null)"
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null &&
    ps -p "$lpid" -o command= 2>/dev/null | grep -q 'watch\.sh'; then
    exit 0
  fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || exit 0
fi
printf '%s' "$$" >"$lock/pid"
# shellcheck disable=SC2064
trap "rm -rf '$lock'" EXIT
trap 'exit 0' INT TERM

# resolve <status-tsv> <dir>
# Echo "<session-id>\t<status>" for the session a TUI in <dir> is most likely
# running: a waiting/busy session wins, then the most recently updated.
resolve() {
  printf '%s\n' "$1" | awk -F'\t' -v d="$2" '
    $4 != d { next }
    {
      live = ($2 == "waiting" || $2 == "busy") ? 1 : 0
      if (!have || (live && !have_live) || (live == have_live && $3 + 0 > up)) {
        sid = $1; status = $2; up = $3 + 0; have = 1; have_live = live
      }
    }
    END { if (have) print sid "\t" status }
  '
}

refresh_pid=''
while tmux list-sessions >/dev/null 2>&1; do
  # Re-read every tick, so a config reload applies without killing the watcher.
  [ "$(get_tmux_option @opencode_watch 'on')" = on ] || exit 0
  prefix="$(get_tmux_option @opencode_session_prefix 'opencode-')"
  forward="$(get_tmux_option @opencode_forward_bell 'on')"
  interval="$(get_tmux_option @opencode_poll_interval '2')"
  # A non-numeric or zero interval would spin the loop at full speed.
  case "$interval" in
  '' | *[!0-9.]* | 0 | 0.0) interval=2 ;;
  esac

  # HTTP only: `opencode api` would start the service when it is down, which
  # would turn this watcher into a daemon keeper.
  status_tsv="$(opencode_status_tsv 2>/dev/null)" || {
    sleep "$interval"
    continue
  }
  [ -n "$status_tsv" ] || {
    sleep "$interval"
    continue
  }

  changed=0
  while IFS=$'\t' read -r sess path; do
    [ -n "$sess" ] || continue
    resolved="$(resolve "$status_tsv" "$path")"
    [ -n "$resolved" ] || continue
    status="${resolved#*$'\t'}"
    prev="$(tmux show-options -qv -t "$sess" @opencode_watch_state 2>/dev/null)"
    [ "$status" = "$prev" ] && continue

    tmux set-option -t "$sess" @opencode_watch_state "$status" 2>/dev/null
    changed=1
    if [ "$forward" = on ]; then
      case "$status" in
      waiting) "$DIR/bell.sh" "$sess" ;;
      idle) [ "$prev" = busy ] && "$DIR/bell.sh" "$sess" ;;
      esac
    fi
  done <<EOF
$(tmux list-panes -a -F $'#{session_name}\t#{pane_current_path}' 2>/dev/null |
  awk -F'\t' -v p="$prefix" 'index($1, p) == 1' | sort -u)
EOF

  # Refresh the picker cache whenever a status changed. Skip while the previous
  # refresh is still running, so a slow agent list cannot pile up jobs.
  if [ "$changed" = 1 ]; then
    if [ -z "$refresh_pid" ] || ! kill -0 "$refresh_pid" 2>/dev/null; then
      "$DIR/picker.sh" --list >/dev/null 2>&1 &
      refresh_pid=$!
    fi
  fi

  sleep "$interval"
done

exit 0
