#!/usr/bin/env bash
# Access to the local OpenCode v2 HTTP API.
#
# OpenCode v2 runs one shared background service per user and every TUI connects
# to it. The service writes its URL and password to a discovery file, so a plain
# curl is enough: no port hunting, and no `opencode api` process spawned on every
# poll (which would otherwise show up in the process scan).
#
# The API is labelled experimental upstream. Keep every request in this file so
# a schema change has exactly one place to land.
#
# Two paths, on purpose:
#   opencode_api_http  curl only. Never starts anything. Used by the watcher.
#   fallback=cli       `opencode api` as a documented fallback. That command may
#                      START the background service when it is not running, so
#                      only user-initiated paths (the picker) ask for it.

# opencode_bin
# The executable from @opencode_command, without arguments.
opencode_bin() {
  local cmd
  cmd="$(get_tmux_option @opencode_command 'opencode')"
  printf '%s' "${cmd%% *}"
}

# opencode_service_file
# Path to the v2 service discovery file.
opencode_service_file() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"
}

# opencode_api_http <path> [directory]
# GET <path> straight from the running service. Prints the body, or fails.
# <directory> scopes location-bound endpoints (permissions, forms) via the
# x-opencode-directory header; without it the server answers for its own cwd.
opencode_api_http() {
  local path="$1" dir="${2:-}" svc url pw user
  svc="$(opencode_service_file)"
  [ -r "$svc" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  url="$(jq -r '.url // empty' "$svc" 2>/dev/null)"
  pw="$(jq -r '.password // empty' "$svc" 2>/dev/null)"
  user="${OPENCODE_SERVER_USERNAME:-opencode}"
  [ -n "$url" ] && [ -n "$pw" ] || return 1
  if [ -n "$dir" ]; then
    curl -fsS -m 3 -u "$user:$pw" -H "x-opencode-directory: $dir" "$url$path" 2>/dev/null
  else
    curl -fsS -m 3 -u "$user:$pw" "$url$path" 2>/dev/null
  fi
}

# opencode_api_cli <path>
# The documented CLI path. May start the background service.
opencode_api_cli() {
  local bin
  bin="$(opencode_bin)"
  command -v "$bin" >/dev/null 2>&1 || return 1
  "$bin" api get "$1" 2>/dev/null
}

# opencode_fetch <path> <outfile> [directory] [fallback]
# Write one response to <outfile>. With fallback=cli, retry through the CLI,
# appending the location query that `opencode api` cannot pass as a header.
opencode_fetch() {
  local path="$1" out="$2" dir="${3:-}" fallback="${4:-}" enc sep
  if opencode_api_http "$path" "$dir" >"$out" 2>/dev/null && [ -s "$out" ]; then
    return 0
  fi
  if [ "$fallback" = cli ]; then
    if [ -n "$dir" ]; then
      enc="$(jq -rn --arg d "$dir" '$d | @uri' 2>/dev/null)"
      sep='?'
      case "$path" in *\?*) sep='&' ;; esac
      opencode_api_cli "${path}${sep}location%5Bdirectory%5D=${enc}" >"$out" 2>/dev/null &&
        [ -s "$out" ] && return 0
    else
      opencode_api_cli "$path" >"$out" 2>/dev/null && [ -s "$out" ] && return 0
    fi
  fi
  return 1
}

# opencode_status_tsv [fallback]
# One line per stored session:
#   session-id \t status \t updated-epoch-seconds \t directory
#
# Status priority:
#   waiting  a permission request or a question is pending
#   busy     the session is in the service's active set
#   error    its last turn failed
#   idle     otherwise
#
# Permissions and forms are location-scoped upstream: a request without a
# location answers for the service's own cwd, which is not where the agents run.
# So they are queried once per directory that currently has an active session.
opencode_status_tsv() {
  local fallback="${1:-}" d dir rc
  d="$(mktemp -d "${TMPDIR:-/tmp}/tmux-opencode-hatch.XXXXXX")" || return 1
  if ! opencode_fetch '/api/session?limit=200&archived=false' "$d/sessions" '' "$fallback"; then
    rm -rf "$d"
    return 1
  fi
  opencode_fetch '/api/session/active' "$d/active" '' "$fallback" ||
    printf '{"data":{}}' >"$d/active"

  # Directories of the sessions that are active right now. A session waiting on a
  # permission or a question is still in the active set.
  jq -nr --slurpfile s "$d/sessions" --slurpfile a "$d/active" '
    (($s[0].data // {})
      | if type == "array" then map({key: .id, value: .}) | from_entries else . end
    ) as $ss
    | (($a[0].data // {})
      | if type == "array" then map(.id) else keys end
    ) as $ids
    | $ids[] as $id
    | ($ss[$id].location.directory // empty)
  ' 2>/dev/null | sort -u >"$d/dirs"

  : >"$d/waiting"
  if [ -s "$d/dirs" ]; then
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      if opencode_fetch '/api/permission/request' "$d/perm" "$dir" "$fallback"; then
        jq -r '.data[]?.sessionID | @json' "$d/perm" >>"$d/waiting" 2>/dev/null
      fi
      if opencode_fetch '/api/form' "$d/form" "$dir" "$fallback"; then
        jq -r '.data[]?.sessionID | @json' "$d/form" >>"$d/waiting" 2>/dev/null
      fi
    done <"$d/dirs"
  fi

  jq -nr --slurpfile s "$d/sessions" --slurpfile a "$d/active" --slurpfile w "$d/waiting" '
    (($s[0].data // {})
      | if type == "array" then map({key: .id, value: .}) | from_entries else . end
    ) as $ss
    | (($a[0].data // {})
      | if type == "array" then map({key: .id, value: .}) | from_entries else . end
    ) as $act
    | ($w | unique) as $waiting
    | $ss | to_entries[]
    | .key as $id | .value as $s
    | (if ($waiting | index($id)) != null then "waiting"
       elif $act[$id] != null then "busy"
       elif $s.outcome == "failed" then "error"
       else "idle" end) as $status
    | [$id, $status,
       (($s.time.updated // $s.time.created // 0) / 1000 | floor),
       ($s.location.directory // "")] | @tsv
  ' 2>/dev/null
  rc=$?
  rm -rf "$d"
  return "$rc"
}
