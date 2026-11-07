#!/usr/bin/env bash
# Interactive picker for running OpenCode agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows and refresh the cache (used by fzf's
#                       async initial load and by the ctrl-x reload).
#   picker.sh --copy <text>
#                       copy <text> to the clipboard (used by ctrl-y).
#   picker.sh --delete <session-id> <pid>
#                       delete one session via the service (ctrl-x).
#   picker.sh --preview <pane>
#                       capture <pane> without its trailing blank lines, which
#                       would otherwise leave fzf's `follow` scrolled onto padding.
#
# Rows come from agents.sh, one per real OpenCode session, paired with the tmux
# pane whose directory hosts it. Two kinds of row jump differently:
#   dedicated  an OpenCode in an `opencode-*` session this plugin launched —
#              resumed in the popup, over the window it was launched from.
#   loose      an OpenCode TUI running in any other pane — focused in place.
# Before jumping, the selected session's tab is selected inside the existing TUI
# (its tab binds are Ctrl+1..0), so several sessions sharing one TUI land on the
# chosen one rather than whichever tab the TUI happened to show. Best-effort: the
# switch is skipped for tab 11+ and when several TUIs share the directory.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

cache="$(picker_cache_path)"

if [ "${1:-}" = '--list' ]; then
  tmp="$cache.$$"
  "$DIR/agents.sh" >"$tmp" 2>/dev/null
  mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
  cat "$cache" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = '--preview' ]; then
  # A line holding only escape codes (from -e) is still blank.
  tmux capture-pane -ept "${2:-}" 2>/dev/null |
    awk -v esc="$(printf '\033')" '
      { line = $0; gsub(esc "\\[[0-9;]*m", "", line) }
      line ~ /^[[:space:]]*$/ { held = held $0 "\n"; next }
      { printf "%s", held; held = ""; print }
    '
  exit 0
fi

if [ "${1:-}" = '--copy' ]; then
  copy_to_clipboard "${2:-}" &&
    tmux display-message "tmux-opencode-hatch: copied ${2:-}"
  exit 0
fi

# --delete <session-id> <pid>
# Remove the selected session (and its child sessions) from the OpenCode
# service. A row without a session id is a live TUI with nothing stored yet, so
# fall back to killing that process.
if [ "${1:-}" = '--delete' ]; then
  sid="${2:-}"
  pid="${3:-}"
  if [ -n "$sid" ] && [ "$sid" != "-" ]; then
    # shellcheck source=api.sh
    . "$DIR/api.sh"
    if opencode_api_delete "/api/session/$sid" >/dev/null 2>&1; then
      exit 0
    fi
    tmux display-message "tmux-opencode-hatch: could not delete $sid" 2>/dev/null
    exit 1
  fi
  [ -n "$pid" ] && [ "$pid" != "-" ] && kill "$pid" 2>/dev/null
  exit 0
fi

for tool in fzf jq "$(get_tmux_option @opencode_command 'opencode')"; do
  command -v "$tool" >/dev/null 2>&1 || {
    tmux display-message "tmux-opencode-hatch: $tool is required for the picker"
    exit 0
  }
done

self="$DIR/picker.sh"
export FZF_DEFAULT_OPTS=''
export OPENCODE_PICKER="$self"

# Arbitrary user fzf options (e.g. custom --bind or --preview-window)
extra_opts=()
fzf_options="$(get_tmux_option @opencode_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

# Load the session list asynchronously. Painting the first frame from the cache
# can be turned off with @opencode_picker_cache, since a cached frame can show a
# stale status.
list_cmd=("$self" --list)
sync_opts=()
now=$(date +%s)
mtime=$(file_mtime "$cache")
if [ "$(get_tmux_option @opencode_picker_cache 'on')" = on ] &&
  [ -s "$cache" ] && [ -n "$mtime" ] && [ $((now - mtime)) -lt 3600 ]; then
  list_cmd=(cat "$cache")
  sync_opts=(--bind "load:unbind(load)+reload-sync($self --list)")
fi

# ctrl-x deletes the selected session through the service, so only that session
# (and its child sessions) goes away — not the other sessions sharing the TUI.
# The reload waits a beat for the delete to settle before agents.sh looks again.
# ctrl-y copies the agent's location (session:window.pane, e.g.
# opencode-88074b0e:0.0) and closes the picker.
sel=$("${list_cmd[@]}" | fzf --ansi --delimiter='\t' --with-nth=7,8,5,9,11 \
  --reverse --cycle --header='OpenCode agents · enter: jump · ctrl-x: delete · ctrl-y: copy' \
  --preview="$self --preview {2}" --preview-window='up,70%,follow' \
  --bind="ctrl-x:execute-silent($self --delete {5} {3})+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-y:execute-silent($self --copy {10})+abort" \
  --bind='change:first' \
  ${sync_opts[@]+"${sync_opts[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)
tabpos=$(printf '%s' "$sel" | cut -f6)

parent=$(tmux show-options -gqv @opencode_parent 2>/dev/null)
session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)

# select_tab <n>
# Make the TUI in this pane show its 1-based tab <n>. The default tab binds are
# Ctrl+1..9 (Ctrl+0 for tab 10), which a terminal encodes with the kitty keyboard
# protocol, so that sequence is sent straight to the pane. Best-effort: a TUI
# that does not understand it simply stays on its current tab, and the jump is
# unaffected.
select_tab() {
  local n="$1" cp seq
  case "$n" in '' | *[!0-9]*) return 0 ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le 10 ] || return 0
  if [ "$n" -eq 10 ]; then cp=48; else cp=$((48 + n)); fi
  seq="$(printf '\033[%d;5u' "$cp")"
  tmux send-keys -t "$pane" -l -- "$seq" 2>/dev/null
  sleep 0.1
}

# Switch the existing TUI to the selected session's tab first, then move to it.
select_tab "$tabpos"

if [ "$kind" = loose ]; then
  # Focus the pane in place on the outer client. This popup closes on its own
  # when the script exits.
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$session" 2>/dev/null
  else
    tmux switch-client -t "$session" 2>/dev/null
  fi
  tmux select-window -t "$pane" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
  exit 0
fi

# Move the parent client to the window the session was launched from (best-effort),
# focus the chosen OpenCode's own window inside that session, then resume it in
# THIS popup over the top. Falls back to resuming over the current window when
# origin/parent are unknown.
origin=$(tmux show-options -qv -t "$session" @opencode_origin 2>/dev/null)
# Fall back to the old option so sessions created before the switch keep working.
[ -n "$origin" ] || origin=$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)
[ -n "$origin" ] && [ -n "$parent" ] &&
  tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

tmux select-window -t "$pane" 2>/dev/null
tmux select-pane -t "$pane" 2>/dev/null
tmux attach-session -t "$session"
