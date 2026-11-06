#!/usr/bin/env bash
# tmux-opencode-hatch
#
# List, monitor status, and jump across nested OpenCode sessions from a single
# popup. tpm runs this file as an executable on tmux startup; it reads user
# options (with sensible defaults) and installs the key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @opencode_launch_key 'y')"
list_key="$(get_tmux_option @opencode_list_key 'u')"

# Launch (or re-attach to) an OpenCode session for the current pane's directory.
# #{pane_current_path} / #{window_id} are expanded by run-shell before the args
# reach the script.
tmux bind-key "$launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch.sh '#{q:pane_current_path}' '#{q:window_id}'"

# Open the session picker. When pressed from inside a session popup, list.sh
# closes that popup first so the picker opens full-size on the outer client.
tmux bind-key "$list_key" \
  run-shell "$CURRENT_DIR/scripts/list.sh '#{q:client_name}'"

# Forward a bell from a dedicated session to its origin window's pane, so
# tmux's own bell machinery (window-status-bell-style, and terminal
# passthrough when that window is visible) picks it up even though the
# session that rang is a separate session from the origin.
if [ "$(get_tmux_option @opencode_forward_bell 'on')" = 'on' ]; then
  tmux set-hook -g alert-bell \
    "run-shell -b \"$CURRENT_DIR/scripts/bell.sh '#{q:hook_session_name}'\""
fi

# Watch the shared OpenCode service for status changes, ring the forwarded bell
# when an agent needs you, and keep the picker cache warm. Shell-only: OpenCode
# exposes live state over a local HTTP API, so there is no hook to install.
if [ "$(get_tmux_option @opencode_watch 'on')" = 'on' ]; then
  tmux run-shell -b "$CURRENT_DIR/scripts/watch.sh"
fi
