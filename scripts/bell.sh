#!/usr/bin/env bash
# Forward a bell from a dedicated OpenCode session to its origin window's pane, so
# tmux's bell machinery picks it up even though the ringing session is separate.
#
#   bell.sh <session-name>
# Called by watch.sh when a session needs attention, and by the alert-bell hook
# when the agent's own terminal rings.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @opencode_session_prefix 'opencode-')"
session="${1:-}"

case "$session" in
"$prefix"*) ;;
*) exit 0 ;;
esac

origin="$(tmux show-options -qv -t "$session" @opencode_origin 2>/dev/null)"
# Fall back to the old option so sessions created before the switch keep working.
[ -n "$origin" ] || origin="$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)"
[ -n "$origin" ] || exit 0

# Skip if the origin is itself a dedicated session, to avoid a forwarding loop.
origin_session="$(tmux display-message -p -t "$origin" '#{session_name}' 2>/dev/null)"
case "$origin_session" in
"$prefix"*) exit 0 ;;
esac

tty="$(tmux display-message -p -t "$origin" '#{pane_tty}' 2>/dev/null)"
[ -n "$tty" ] && printf '\a' >"$tty" 2>/dev/null
exit 0
