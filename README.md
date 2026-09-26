<img src="scripts/icon_1024.png" width="128" alt="Atoll icon">

# Atoll

Dynamic-island-style notch app for macOS: hover the notch (or hit the hotkey)
and it expands into a tabbed workspace that's always with you — Claude Code
FleetView, a scratchpad, a shell, or any terminal command you configure.

- Collapsed: black pill under the notch.
- Hover or hotkey (default ⌃⌥ Space): expands into the selected tab.
- Startup: nothing runs until you expand. Optionally pick "First Tab" on
  launch and/or pre-warm panes (right-click menu) for an instant island.
- Tabs: each is a terminal running a command of your choice (processes keep
  running while collapsed or on another tab), or a native notes scratchpad.
- Right-click: auto-focus toggle, launch directory for new sessions,
  hotkey preset, theme (tarmac / bubblegum / phosphor / pool), sharp-corner
  toggle, edit tabs, quit.

> Formerly **Claude Island** (a single embedded `claude agents` terminal).
> Atoll = a ring of many islands.

## Tabs

Tabs live in `~/.config/atoll/tabs.json` (created with defaults on first
launch; right-click → "Edit Tabs…" opens it; edits are picked up on the next
expand). Each entry is a terminal command, or `"type": "notes"` for the
scratchpad (autosaved to `~/.config/atoll/notes.md`):

```json
[
  { "name": "Fleet", "command": "~/.local/bin/claude agents" },
  { "name": "Notes", "type": "notes" }
]
```

Add your own with the "+" button: one click on a suggested tool found on
your PATH (herdr, lazygit, btop, …) or a Shell/Notes pane, or type a name
and any command. Right-click a tab to remove it or flip it between terminal
and widget. An entry without `command` opens a
plain login shell (`{ "name": "Shell" }`). Commands run via `zsh -lc` in the
configured launch directory, so anything on your PATH works — e.g.
`{ "name": "herdr", "command": "herdr" }`.

### Build-your-own islands

Beyond terminals, a tab can be:

- **Widget** — polled command output rendered as text (no pty):
  ```json
  { "name": "git", "type": "widget", "command": "git status --short --branch", "refresh": 10 }
  ```
  `refresh` is seconds (default 5). Or right-click any command tab →
  "Use as Widget" to convert it in place.
- **Web pane** — an embedded browser pinned to a URL; logins survive tab
  switches:
  ```json
  { "name": "CI", "type": "web", "url": "https://github.com/notifications" }
  ```
- **Browser** — a web pane with its own page tabs and an address bar (url or
  search). "+" → Browser, or paste an `https://` url into the command field.
  ⌘T / ⌘W open and close page tabs, ⌘L focuses the address bar, ⌘⇧[ / ⌘⇧]
  cycle, ⌘-click opens a link in a background tab. Open pages are restored on
  relaunch; `url` (optional) is the first page:
  ```json
  { "name": "Browser", "type": "browser" }
  ```

### atollctl — script the island

The app listens on a local socket (`~/.config/atoll/atoll.sock`) so anything
can drive it. The client ships inside the app bundle:

```sh
/Applications/Atoll.app/Contents/MacOS/atollctl toggle
/Applications/Atoll.app/Contents/MacOS/atollctl select ci
/Applications/Atoll.app/Contents/MacOS/atollctl flash "✓ build passed"
/Applications/Atoll.app/Contents/MacOS/atollctl status   # expanded/selected/tabs/live
```

Handy alias: `alias atoll='/Applications/Atoll.app/Contents/MacOS/atollctl'`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/pjoachims/atoll/main/install.sh | sh
```

Downloads the latest [release](https://github.com/pjoachims/atoll/releases)
into `/Applications` and launches it (replacing an old Claude Island.app if
present; prefs carry over).

It also asks where new sessions should start, defaulting to the first checkout
root it finds (`~/Documents/git`, `~/Developer`, `~/repos`, `~/dev`, `~/src`,
`~/code`, `~/projects`, …, else `~`). Answer non-interactively with `ATOLL_DIR`,
or `skip` to leave the setting to the app:

```sh
curl -fsSL .../install.sh | ATOLL_DIR=~/code sh
```

You can change it later from the right-click menu: "New sessions start in" lists
that directory and the git checkouts inside it, and "Choose Start Folder…" opens
a picker for anywhere else.

If you download the zip in a browser instead, macOS will block the app ("Apple
could not verify...") because it's ad-hoc signed, not notarized. Either use the
installer above (curl downloads skip quarantine), or after the blocked launch go
to System Settings → Privacy & Security → "Open Anyway".

### Build from source

Requires Xcode 15+ / Swift 5.9 (macOS 14+).

```sh
./build.sh          # -> Atoll.app (also syncs /Applications copy)
open "Atoll.app"
```

Launch at login: System Settings → General → Login Items → add Atoll.app.

## Uninstall

Quit the app, delete Atoll.app, `rm -rf ~/.config/atoll`. If you installed a
pre-0.3 Claude Island: remove the `claude-island` hook entries from
`~/.claude/settings.json` and `rm -rf ~/.claude/island`.
