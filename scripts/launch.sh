#!/usr/bin/env bash
# Launch (or re-attach to) an OpenCode session for a directory, shown in a popup.
# Args: <dir> [origin-window-id]   (both expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"

prefix="$(get_tmux_option @opencode_session_prefix 'opencode-')"
cmd="$(get_tmux_option @opencode_command 'opencode')"
args="$(get_tmux_option @opencode_args '')"
[ -n "$args" ] && cmd="$cmd $args"
w="$(get_tmux_option @opencode_popup_width '90%')"
h="$(get_tmux_option @opencode_popup_height '90%')"

session="${prefix}$(session_hash "$path")"

if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux display-message '🫪 Popup window already open'
  exit 0
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
  [ -d "$path" ] || {
    tmux display-message "tmux-opencode-hatch: $path no longer exists"
    exit 0
  }
  tmux new-session -d -s "$session" -c "$path" "$cmd"
fi

# Close the popup when OpenCode exits, even under a global detach-on-destroy off.
tmux set-option -t "$session" detach-on-destroy on

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @opencode_origin "$window"

title=" OpenCode "
tmux display-popup -w "$w" -h "$h" -b rounded -T "$title" -E "tmux attach-session -t '$session'"
