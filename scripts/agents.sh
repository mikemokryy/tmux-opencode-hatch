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
# Rows are defined by real OpenCode sessions (`ses_...`), not by the generated
# tmux session name (a hash of the directory). The TUI records the tabs it has
# open in its own state file, and those tabs are authoritative for the pane whose
# working directory matches. Only when a directory reports no tab state (a fresh
# TUI, or the state file is unavailable) do active root sessions, then recently
# used ones, then the most recently updated one stand in. Child sessions
# (subagents) are skipped. The API has no pane/tty, so rows for one directory
# share one jump target.
#
#   Row: rank \t pane_id \t pid \t kind \t sid \t tabpos \t icon \t age \t title \t loc \t path
#   rank/pane_id/pid/kind/tabpos/loc are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"
# shellcheck source=api.sh
. "$DIR/api.sh"

prefix="$(get_tmux_option @opencode_session_prefix 'opencode-')"

# ttl_seconds <value>
# Parse the fallback window into seconds: a plain number of seconds, or a
# duration with an s/m/h/d suffix (90m, 6h, 1d). Anything invalid falls back to
# the 6h default. 0 limits the fallback to active sessions.
ttl_seconds() {
  local v="$1" n unit
  case "$v" in
  '' | *[!0-9smhd]*) printf '%s' 21600; return ;;
  esac
  unit="${v: -1}"
  case "$unit" in
  s | m | h | d) n="${v%?}" ;;
  *) n="$v"; unit=s ;;
  esac
  case "$n" in
  '' | *[!0-9]*) printf '%s' 21600; return ;;
  esac
  case "$unit" in
  s) printf '%s' "$n" ;;
  m) printf '%s' $((10#$n * 60)) ;;
  h) printf '%s' $((10#$n * 3600)) ;;
  d) printf '%s' $((10#$n * 86400)) ;;
  esac
}

# Fallback window (seconds) for directories that report no open tabs. Active
# sessions are always listed there; recently used ones within this window too.
# Directories with open tabs are unaffected.
ttl="$(ttl_seconds "$(get_tmux_option @opencode_session_ttl '6h')")"

# The picker is user-initiated, so allow the documented CLI fallback here. The
# watcher deliberately does not: `opencode api` starts the service when it is down.
status_tsv="$(opencode_status_tsv cli)" || exit 0
[ -n "$status_tsv" ] || exit 0

# Open tabs from the TUI's own state. Best-effort; if it is unavailable the
# active-session fallback below still produces rows.
tabs_tsv="$(opencode_tabs_tsv)"

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
  [ -n "$tabs_tsv" ] && printf '%s\n' "$tabs_tsv" | sed $'s/^/B\t/'
  printf '%s\n' "$status_tsv" | sed $'s/^/S\t/'
} | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" -v prefix="$prefix" -v ttl="$ttl" '
  # agent_pid <tty>
  # The process representing the agent in this pane, or "" when the pane has no
  # live OpenCode. Sets kind for the row. A dedicated pane prefers the OpenCode
  # child (e.g. `fish -c opencode`) so ctrl-x kills the TUI itself, and falls
  # back to the pane wrapper process.
  function agent_pid(tty,   proc) {
    if (index(sess[tty], prefix) == 1) {
      proc = tui_pid[tty]
      if (proc == "") proc = ppid[tty]
      if (proc == "" || !(proc in alive)) return ""
      kind = "dedicated"
    } else {
      proc = tui_pid[tty]
      if (proc == "") return ""
      kind = "loose"
    }
    return proc
  }

  # emit <tty> <session-id> [fallback-title] [tab-position]
  # Print one picker row for <session-id> on the pane. An empty id means the pane
  # is live but has no stored session yet (shown as "?"). <fallback-title> is used
  # when the session is not in the API list (e.g. a tab whose session aged out).
  # <tab-position> is the 1-based tab index in the TUI (0 when not a tab).
  function emit(tty, sid, ftitle, tabpos,   status, icon, rank, secs, mins, age, t, p, s) {
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

    t = (sid != "" && (sid in stitle)) ? stitle[sid] : ftitle
    if (t == "") t = "-"
    s = (sid == "") ? "-" : sid

    p = path[tty]
    if (index(p, home) == 1) p = "~" substr(p, length(home) + 1)

    printf "%d\t%d\t%s\t%s\t%s\t%s\t%d\t%s\t%5s\t%s\t%s\t%s\n",
      secs, rank, pane[tty], pid, kind, s, tabpos + 0, icon, age, t, loc[tty], p
  }

  $1 == "P" { alive[$2] = 1; next }
  $1 == "O" { tui_pid[$3] = $2; tui_sid[$3] = $4; next }
  $1 == "T" {
    tty = $2; sub(/^\/dev\//, "", tty)
    pane[tty] = $3; ppid[tty] = $4; sess[tty] = $5; path[tty] = $6; loc[tty] = $7
    pane_order[npane++] = tty
    next
  }
  $1 == "B" {
    d = $2; id = $3
    tn[d]++
    tid[d, tn[d]] = id
    ttitle[d, tn[d]] = $4
    next
  }
  $1 == "S" {
    id = $2; st[id] = $3; upd[id] = $4 + 0; sdir[id] = $5; stitle[id] = $6
    sparent[id] = $7
    sess_order[nsess++] = id
    next
  }
  END {
    # tabs.json is keyed by cwd only. When several TUIs share a directory the
    # per-tab index cannot be attributed to one of them, so tab switching is
    # skipped there (tabpos 0) instead of risking the wrong tab.
    for (i = 0; i < npane; i++) {
      tty = pane_order[i]
      if (agent_pid(tty) != "") panes_in[path[tty]]++
    }

    # Pass 1: a TUI launched with an explicit --session owns that session, so
    # claim it before the directory-wide matching below can pick it.
    for (i = 0; i < npane; i++) {
      tty = pane_order[i]
      sid = tui_sid[tty]
      if (sid == "" || !(sid in st)) continue
      pid = agent_pid(tty)
      if (pid == "") continue
      d = path[tty]
      tp = 0
      if (panes_in[d] <= 1)
        for (j = 1; j <= tn[d]; j++)
          if (tid[d, j] == sid) { tp = j; break }
      emit(tty, sid, "", tp)
      claimed[sid] = 1
      pinned[tty] = 1
    }

    # Pass 2: pair the remaining panes by working directory. The tabs the TUI
    # reports for that directory are authoritative: a session that is not open
    # as a tab is not listed. When a directory has no tab state at all (fresh
    # TUI, or the state file is unavailable), fall back to active root sessions,
    # optionally recently used ones, then the most recent root session. A session
    # is claimed by the first pane that shows it, so rows never duplicate.
    for (i = 0; i < npane; i++) {
      tty = pane_order[i]
      if (tty in pinned) continue
      pid = agent_pid(tty)
      if (pid == "") continue
      d = path[tty]

      shown = 0
      for (j = 1; j <= tn[d]; j++) {
        id = tid[d, j]
        if (id in claimed) continue
        tp = (panes_in[d] <= 1) ? j : 0
        emit(tty, id, ttitle[d, j], tp)
        claimed[id] = 1
        shown = 1
      }
      if (shown) continue

      n = 0
      for (j = 0; j < nsess; j++) {
        id = sess_order[j]
        if (id != "" && sdir[id] == d && !(id in claimed) && sparent[id] == "" &&
            (st[id] == "waiting" || st[id] == "busy" ||
             (ttl > 0 && now - upd[id] <= ttl)))
          sel[++n] = id
      }
      for (k = 1; k <= n; k++) {
        emit(tty, sel[k], "", 0)
        claimed[sel[k]] = 1
      }
      if (n > 0) continue

      # Nothing recent either: the most recently updated root session in the
      # directory stands in.
      best = ""
      for (j = 0; j < nsess; j++) {
        id = sess_order[j]
        if (id != "" && sdir[id] == d && !(id in claimed) && sparent[id] == "" &&
            (best == "" || upd[id] > upd[best]))
          best = id
      }
      if (best != "") {
        emit(tty, best, "", 0)
        claimed[best] = 1
        continue
      }

      # A live TUI whose session is not in the API yet, or whose sessions were
      # already claimed by another pane in the same directory.
      emit(tty, "", "", 0)
    }
  }
' | sort -t$'\t' $sort_keys | cut -f2-
# The age column mixes units ("5m", "3h", "2d"), so the sort runs on a leading
# seconds column, cut off once it has served.

exit 0
