# tmux-opencode-hatch

A tmux plugin that runs an [OpenCode](https://opencode.ai) session in a popup for
each project directory. Open the hatch, hand OpenCode the work, close it and get
back to your editor. Each session lives in its own nested tmux session, so
closing the hatch never interrupts it. When you want to check in, an `fzf`
picker lists every OpenCode session in your TUIs, shows what each one is doing,
and jumps you straight to it. And when a session finishes or needs your
attention, it rings a bell that highlights the window you launched it from — so
you know where to go without even opening the picker.

Simple by design: it's just a few shell scripts. No hooks to install, no
JavaScript plugin. Status comes from the background service OpenCode already
runs; a tiny shell watcher forwards bells.

> Adapted from [craftzdog/tmux-claude-hatch](https://github.com/craftzdog/tmux-claude-hatch)
> (MIT, © Takuya Matsuyama). The Claude Code status sources were replaced with
> OpenCode v2's local HTTP API.

## Why / philosophy

- **Who it's for**
  - People who want to stay in their editor — (Neo)vim, Emacs — in the main tmux
    session
  - People who still read, write, and review the code themselves
  - People who'd rather have a small tool than a full-blown one just to manage
    agent sessions
- **Who it's not for**
  - People whose focus is the agent's chat interface rather than the code
  - People who want one tool for sessions across several AI providers — this one
    is OpenCode only
  - People who run a swarm of agents and don't read or write code themselves

## Features

- **A central picker** (`prefix` + `u`) listing every OpenCode session open in
  your TUIs — several in one project directory, and any running loose in an
  ordinary pane.
- **Live status** per agent — `working` / `waiting` / `idle`, plus `error` when a
  turn failed — read from the OpenCode service that all TUIs already talk to. No
  setup.
- **A live preview** of each agent's screen right in the picker.
- **Smart jump** — selecting an agent switches its TUI to that session's tab,
  moves your client to the window it was launched from, then resumes it in a
  popup over it.
- **A launcher** (`prefix` + `y`) that opens/attaches an OpenCode session for the
  current directory.
- **Quick delete** (`ctrl-x`) of the highlighted session (its child sessions too)
  from the picker.
- **Copy location** (`ctrl-y`) — puts an agent's `session:window.pane` target
  on the clipboard, ready for `tmux send-keys -t` and friends.
- **Bell forwarding** — a bell in a dedicated session highlights the window you
  launched it from, so you notice even without opening the picker. Works out of
  the box: a small watcher polls the local API and rings when a session starts
  waiting on you or finishes a turn.

## Prerequisites

- **OpenCode v2** (`opencode --version`) — the plugin reads the shared background
  service's HTTP API. On v1 there is no shared service, so status would be empty.
- **tmux ≥ 3.2** (for `display-popup`)
- **[fzf](https://github.com/junegunn/fzf)** ≥ 0.48 — the picker UI (for
  `reload-sync`)
- **[jq](https://jqlang.org/)** — parses the API responses
- **[curl](https://curl.se/)** — talks to the local service
- bash; macOS or Linux

## Installation

### Manual (recommended while local)

```sh
git clone ~/Developer/tmux-opencode-hatch ~/clone/path   # or copy the directory
```

Add to `~/.tmux.conf` (or `~/.config/tmux/tmux.conf`), then reload (`prefix` +
<kbd>r</kbd> or `tmux source ~/.tmux.conf`):

```tmux
run-shell ~/clone/path/opencode_hatch.tmux
```

### tpm

Once you publish a fork, add it to `~/.tmux.conf` and hit `prefix` + <kbd>I</kbd>:

```tmux
set -g @plugin 'you/tmux-opencode-hatch'
```

> **Keybinding note:** by default the plugin binds `prefix` + `y` (launch) and
> `prefix` + `u` (list). If your config binds those elsewhere, either change the
> [options](#options), or make sure the plugin loads **after** your own bindings
> (put `run '~/.tmux/plugins/tpm/tpm'` _after_ them) so the one you want wins.

## Usage

| Key            | Action                                                                        |
| -------------- | ----------------------------------------------------------------------------- |
| `prefix` + `y` | Launch (or re-attach to) an OpenCode session for the current directory, in a popup |
| `prefix` + `d` | Close the popup and go back to your window; the OpenCode session keeps running |
| `prefix` + `u` | Open the agent picker                                                         |

Inside the picker:

| Key                       | Action                                                                         |
| ------------------------- | ------------------------------------------------------------------------------ |
| `enter`                   | Jump to the selected session                                                  |
| `ctrl-x`                  | Delete the highlighted session (and its child sessions)                        |
| `ctrl-y`                  | Copy the highlighted agent's location (e.g. `opencode-88074b0e:0.0`) and close |
| `↑` / `↓`, type to filter | fzf navigation                                                                 |

Agents needing your attention (`waiting`, `idle`) sort to the top. Set
`@opencode_sort 'recent'` to sort by last activity instead, regardless of status.

Every OpenCode session gets its own row, identified by its real `ses_...` id.
Rows are the tabs the TUI has open in that directory — a session that is not open
as a tab is not listed, even if it was used recently. Child sessions (subagents)
are skipped. When a directory reports no tab state at all (a fresh TUI, or the
state file is unavailable), running sessions and sessions used within
`@opencode_session_ttl` stand in; if none match, its most recently updated root
session is shown. A dedicated session is found through the tmux session this
plugin created; a TUI you started by hand in an ordinary pane shows up as
`loose`. Sessions are paired with their tmux pane by working directory, so a
freshly started TUI shows `?` until its first session exists. The API exposes no
pane or tty, so rows for the same directory share one underlying pane; selecting
a row first switches that TUI to the session's tab (its default `Ctrl+1`…`Ctrl+0`
tab binds), then jumps to the pane, so multiple tabs in one TUI land on the one
you chose.

The tab switch is best-effort: it assumes the default tab binds, and is skipped
for the 11th tab and beyond, and when more than one TUI shares the directory
(the TUI state file is keyed by directory, so the index cannot be attributed).
In those cases the jump still lands on the pane, showing its current tab.

### How status works

OpenCode v2 runs **one shared background service** per user; every TUI connects
to it. The plugin reads that service through its discovery file
(`${XDG_STATE_HOME:-~/.local/state}/opencode/service.json`) and asks:

| Question | Endpoint |
| -------- | -------- |
| Which sessions are running? | `GET /api/session/active` |
| Which tabs are open in a TUI? | the TUI's `tabs.json` state file |
| Is a permission pending? | `GET /api/permission/request` |
| Is a question pending? | `GET /api/form` |
| What is this session's title / directory / last activity? | `GET /api/session` |

This is what replaces Claude Code's `claude agents` command. There is no pid or
tty in the API, so the plugin joins sessions to tmux panes by
`location.directory` ↔ `pane_current_path` instead. Rows come from the tabs the
TUI reports as open, or — when a directory reports no tab state — running or
recently used root sessions, and each is identified by its real `ses_...` id.
Status is aggregated per directory for bells
(`waiting` wins over `busy`, then the most recent session), so one waiting
session cannot hide behind a busy one. Permissions and forms are location-scoped
upstream, so they are queried once per directory that has a running session (a
request without a location answers for the service's own cwd). At most the newest
200 stored sessions are considered.

> **Note:** the HTTP API is documented by OpenCode as *experimental*. All access
> lives in [`scripts/api.sh`](./scripts/api.sh), so a schema change has one place
> to fix. The watcher uses curl only and never starts anything; the picker falls
> back to `opencode api get …`, which may start the background service if it is
> not running.

## Options

Set any of these before the plugin loads (defaults shown):

```tmux
set -g @opencode_launch_key     'y'          # prefix key: launch/open for current dir
set -g @opencode_list_key       'u'          # prefix key: open the picker
set -g @opencode_command        'opencode'   # command run in new sessions
set -g @opencode_args           ''           # extra args appended to the command
set -g @opencode_session_prefix 'opencode-'  # tmux session name prefix
set -g @opencode_popup_width    '90%'        # popup width
set -g @opencode_popup_height   '90%'        # popup height
set -g @opencode_fzf_options    ''           # extra options passed to the fzf picker
set -g @opencode_picker_cache   'on'         # paint the picker's first frame from a cache
set -g @opencode_sort           'status'     # picker order: 'status' or 'recent'
set -g @opencode_session_ttl    '6h'         # no-tab fallback window: sessions used this recently (0 = no recency window)
set -g @opencode_forward_bell   'on'         # highlight the origin window on a bell
set -g @opencode_watch          'on'         # poll status, forward bells, refresh cache
set -g @opencode_poll_interval  '2'          # seconds between status polls
```

`@opencode_session_ttl` accepts a duration suffix (`30m`, `6h`, `1d`) or a plain
number of seconds. It only applies to a directory whose TUI reports no open tabs;
`0` limits that fallback to running sessions, with the most recently updated
session in the directory as the last resort.

For example, to auto-approve permissions in launched sessions:

```tmux
set -g @opencode_args '--auto'
```

## Customizations

### Changing the poll interval

The bell watcher asks the local API every `@opencode_poll_interval` seconds
(default `2`). Lower it for snappier bells, raise it to spend less CPU:

```tmux
set -g @opencode_poll_interval '1'
```

Options are re-read every tick, so a config reload applies without restarting
the watcher. Set `@opencode_watch 'off'` to disable polling entirely — the running
watcher exits at its next tick. Bell forwarding still works for bells OpenCode
itself emits, and `@opencode_forward_bell 'off'` turns even that off.

### Customizing the fzf picker

`@opencode_fzf_options` is passed straight to `fzf`, so you can add your own
bindings. Here is a vim-style example:

```tmux
set -g @opencode_fzf_options "\
  --prompt 'nav> ' \
  --bind 'j:down' \
  --bind 'k:up' \
  --bind 'q:abort' \
  --bind 'x:execute-silent(kill {3})+reload(sleep 0.3; \$OPENCODE_PICKER --list)' \
  --bind 'i:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'a:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'esc:rebind(j,k,q,i,a,x)+change-prompt(nav> )'"
```

The picker opens in **nav** mode:

| Key       | Action                                                  |
| --------- | ------------------------------------------------------- |
| `j` / `k` | move down / up                                          |
| `i` / `a` | switch to **filter** mode — type to fuzzy-match         |
| `x`       | kill the highlighted agent (like the built-in `ctrl-x`) |
| `q`       | close the picker                                        |
| `enter`   | jump to the agent (both modes)                          |
| `esc`     | filter mode → back to nav                               |

Only the bound keys are special in nav mode; any other key still filters as you
type. `x` reloads the list through `$OPENCODE_PICKER`, a path the picker exports
for exactly this — write it as `\$OPENCODE_PICKER` inside the double-quoted value
above so tmux stores a literal `$` (in a single-quoted value, use a bare
`$OPENCODE_PICKER`).

## License

[MIT](LICENSE) © Takuya Matsuyama — adapted for OpenCode.
