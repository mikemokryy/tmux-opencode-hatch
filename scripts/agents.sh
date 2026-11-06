#!/usr/bin/env bash
# Emit one picker row per OpenCode session that lives in a tmux pane.
#
# OpenCode v2 keeps the live state in a shared background service, and scripts/
# api.sh reads it: which sessions are running, and which are blocked on a
# permission request or a question. That replaces Claude Code's per-process
# `agents` command — there is no pid or tty in the API, so identity here is the
# tmux pane. Two kinds of pane produce a row:
#
#   dedicated  a session this plugin launched (`@opencode_session_prefix`),
#              running the agent as the pane's own process.
#   loose      an OpenCode TUI started by hand in any other pane.
#
# A stored session is matched to its pane by working directory (the API reports
# `location.directory`, tmux reports `pane_current_path`). When several sessions
# share a directory, the running one wins, then the most recently active.
#
#   Row: rank \t pane_id \t pid \t kind \t icon \t age \t loc \t path
#   rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"
# shellcheck source=api.sh
. "$DIR/api.sh"

prefix="$(get_tmux_option @opencode_session_prefix 'opencode-')"

# The picker is user-initiated, so allow the documented CLI fallback here. The
# watcher deliberately does not: `opencode api` starts the service when it is down.
status_tsv="$(opencode_status_tsv cli)" || exit 0
[ -n "$status_tsv" ] || exit 0

# ps output is parsed twice: once for liveness/tty, once for the OpenCode TUIs
# themselves. `ps` gives a bare tty name (ttys001); tmux gives /dev/ttys001.
ps_out="$(ps -axo pid=,tty=,command= 2>/dev/null)"

# status: rank asc (what needs you floats up), then age asc so whatever just went
# idle sits at the top of its group. recent: age asc alone.
if [ "$(get_tmux_option @opencode_sort 'status')" = recent ]; then
  sort_keys='-k1,1n'
else
  sort_keys='-k2,2n -k1,1n'
fi

{
  printf '%s\n' "$ps_out" | awk '$2 != "" && $2 != "??" { print "P\t" $1 "\t" $2 }'
  printf '%s\n' "$ps_out" | awk '
    {
      pid = $1; tty = $2
      cmd = ""; for (i = 3; i <= NF; i++) cmd = cmd (i > 3 ? " " : "") $i
      n = split(cmd, a, / +/)
      idx = 0
      for (i = 1; i <= n; i++) {
        b = a[i]; sub(/.*\//, "", b)
        if (b ~ /^opencode(-v2)?$/) { idx = i; break }
      }
      if (!idx) next
      # Only a direct launch, or one through a JS/package runner, is a TUI.
      # This keeps `vim opencode` and the like out of the picker.
      if (idx > 2) next
      if (idx == 2) {
        first = a[1]; sub(/.*\//, "", first)
        if (first !~ /^(node|bun|npx|bunx)$/) next
      }
      # A subcommand after the executable (api, service, serve, run, session,
      # ...) is not a TUI. Flags, or nothing, mean the interactive client.
      if (idx < n && a[idx + 1] !~ /^-/) next
      sid = ""
      for (i = idx + 1; i <= n; i++) {
        if ((a[i] == "-s" || a[i] == "--session") && i < n) { sid = a[i + 1]; break }
        if (a[i] ~ /^--session=/) { sid = substr(a[i], 11); break }
      }
      print "O\t" pid "\t" tty "\t" sid
    }
  '
  tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{pane_pid}\t#{session_name}\t#{pane_current_path}\t#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
  printf '%s\n' "$status_tsv" | sed $'s/^/S\t/'
} | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" -v prefix="$prefix" '
  $1 == "P" { alive[$2] = 1; next }
  $1 == "O" { tui_pid[$3] = $2; tui_sid[$3] = $4; next }
  $1 == "T" {
    tty = $2; sub(/^\/dev\//, "", tty)
    pane[tty] = $3; ppid[tty] = $4; sess[tty] = $5; path[tty] = $6; loc[tty] = $7
    panes[tty] = 1
    next
  }
  $1 == "S" {
    id = $2; st[id] = $3; upd[id] = $4 + 0; sdir = $5
    if (sdir != "") {
      if (!(sdir in best) || upd[id] > upd[best[sdir]]) best[sdir] = id
      if (st[id] == "waiting" || st[id] == "busy") {
        if (!(sdir in blive) || upd[id] > upd[blive[sdir]]) blive[sdir] = id
      }
    }
    next
  }
  END {
    for (tty in panes) {
      dedicated = (index(sess[tty], prefix) == 1)

      if (dedicated) {
        # Prefer the OpenCode child (e.g. `fish -c opencode`) so ctrl-x kills the
        # TUI itself; the pane wrapper process is the fallback.
        pid = tui_pid[tty]
        if (pid == "") pid = ppid[tty]
        if (pid == "" || !(pid in alive)) continue
        kind = "dedicated"
      } else {
        pid = tui_pid[tty]
        if (pid == "") continue
        kind = "loose"
      }

      sid = tui_sid[tty]
      if (sid == "" || !(sid in st)) {
        if (path[tty] in blive) sid = blive[path[tty]]
        else if (path[tty] in best) sid = best[path[tty]]
      }

      status = (sid != "" && (sid in st)) ? st[sid] : "unknown"

      if      (status == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
      else if (status == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
      else if (status == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
      else if (status == "error")   { icon = "\033[35m●\033[0m error  "; rank = 2 }  # magenta - last turn failed
      else                          { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - no session yet

      secs = (sid != "" && (sid in upd)) ? now - upd[sid] : 1e12
      mins = int(secs / 60)
      if      (secs >= 1e12) age = "-"
      else if (mins < 60)    age = mins "m"
      else if (mins < 2880)  age = int(mins / 60) "h"
      else                   age = int(mins / 1440) "d"

      p = path[tty]
      if (index(p, home) == 1) p = "~" substr(p, length(home) + 1)

      printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%5s\t%s\n",
        secs, rank, pane[tty], pid, kind, icon, age, loc[tty], p
    }
  }
' | sort -t$'\t' $sort_keys | cut -f2-
# The age column mixes units ("5m", "3h", "2d"), so the sort runs on a leading
# seconds column, cut off once it has served.

exit 0
