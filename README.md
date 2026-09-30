# herdr-nvim

Use a [Herdr](https://herdr.dev) session from Neovim like a file tree.
Spaces are folders and terminals/agents are files, with live agent status, and any terminal opens as a Neovim `:terminal`.

- **Tree** - a file-explorer-style view of the session. It borrows its look (icons, indent guides, width, side) from your own file explorer: snacks.nvim's explorer or neo-tree.
- **Picker** - a snacks.nvim picker over spaces and agents with a live, colored preview of each terminal's screen.

Herdr keeps running the agents; Neovim is just another client.
Works with a local Herdr server or one on a remote machine over SSH.

## How it works

Herdr's server exposes two sockets per session:

- `herdr.sock` - the JSON API (one JSON object per line). herdr-nvim uses it for `session.snapshot`, actions like `tab.create` and `pane.rename`, and `events.subscribe` to keep the tree and picker live.
- `herdr-client.sock` - the client protocol. herdr-nvim does not speak it itself: each terminal is `herdr terminal attach <terminal_id>`, which streams one pane's raw terminal output, and Neovim's built-in terminal renders it.

For a remote server, herdr-nvim opens exactly one SSH connection per Neovim, like Herdr's own `herdr --remote`.
Both sockets are forwarded over it to local unix sockets, and terminals attach with your local `herdr` through the forwarded client socket.
Any number of open terminals costs no extra SSH sessions, and closing one detaches immediately.
Without a local `herdr` (or with one that is not protocol-compatible with the server), terminals fall back to running `herdr terminal attach` on the remote, one SSH session per open terminal.

## Requirements

On the machine running Neovim:

- Neovim 0.10+
- For a remote server: OpenSSH, with non-interactive access to the host (`ssh -o BatchMode=yes <host> true` must succeed: keys, an agent, or a `ProxyCommand`)
- Recommended: [Herdr](https://herdr.dev) installed locally. Required for a local server; for a remote server it enables the single-connection attach described above
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) (picker with live preview, explorer styling) and a [Nerd Font](https://www.nerdfonts.com)

On the remote machine:

- Herdr, on the SSH session's `PATH` or in `~/.local/bin` (see `remote_path`)
- A Herdr server for the session. herdr-nvim offers to start it when it is not running (`auto_start`)
- SSH unix-socket forwarding allowed (OpenSSH's default `AllowStreamLocalForwarding yes`)

Run `:checkhealth herdr` to check all of this for the current connection.

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "thomasian06/herdr-nvim",
  opts = {
    -- remote = "devbox", -- SSH target running the Herdr server; omit for a local server
    -- session = "main",
  },
}
```

Other plugin managers: add `thomasian06/herdr-nvim` and call `require("herdr").setup({})`.

### Options

```lua
require("herdr").setup({
  remote = nil, -- SSH target (e.g. "devbox"); nil = last connection used, else local
  session = "main", -- Herdr session name
  profiles = {}, -- e.g. { { name = "devbox", remote = "devbox", session = "main" } }
  auto_start = "ask", -- start a missing Herdr server: "ask" | true | false
  remote_attach = "auto", -- "auto" (local herdr via forwarded socket when possible) | "ssh"
  herdr_bin = "herdr", -- local herdr binary
  remote_path = { "$HOME/.local/bin" }, -- prepended to PATH on the remote
  keymaps = {
    toggle = "<leader>aa", -- toggle the tree
    pick = "<leader>ap", -- spaces/agents picker
    connect = "<leader>ac", -- connect to a server/profile
  }, -- set a key (or all of `keymaps`) to false to disable
  tree = { -- unset values are borrowed from your file explorer
    width = nil,
    position = nil, -- "left" | "right"
    icons = nil, -- e.g. { agent = "A ", shell = "$ ", space_open = "- ", space_closed = "+ " }
    indent = nil, -- e.g. { vertical = "| ", middle = "|-", last = "`-" }
  },
})
```


## Commands

| Command | |
| --- | --- |
| `:Herdr` / `:Herdr toggle` | Toggle the tree |
| `:Herdr pick` | Spaces/agents picker (snacks.nvim; falls back to `vim.ui.select`) |
| `:Herdr open <pane_id>` | Open a terminal, e.g. `:Herdr open w1:p1` |
| `:Herdr refresh` | Re-fetch the session snapshot |
| `:Herdr connect [profile\|host[:session]]` | Connect to a server; without an argument, pick one |
| `:Herdr disconnect` | Disconnect |
| `:Herdr save [name]` | Save the current connection as a profile |
| `:Herdr forget <name>` | Remove a saved profile |

## Connections

One connection is active at a time; the tree's root line shows it.
`:Herdr connect` (`<leader>ac`, or `C` in the tree) offers:

- the current connection and local Herdr
- `profiles` from `setup()`
- Herdr's own saved machines (`herdr machine add ...`), so machines set up for Herdr work here too
- profiles saved with `:Herdr save`
- **New connection…**, which asks for an SSH target and session, then offers to save it

Saved profiles and the last connection used live in `stdpath("data")/herdr-nvim/connections.json`.
At startup herdr-nvim connects to `remote`/`session` from `setup()` when given, otherwise to the last connection used.
Switching detaches and closes the previous server's terminals.

## Tree

```
󰒋 devbox:main
├╴󰝰 api-server                         ○
│ ├╴󰚩 api-server  claude               ○
│ └╴ dev server
└╴󰝰 website                            ●
  ├╴󰚩 fix-login  codex                 ●
  └╴󰚩 add-tests  pi                    ✓
```

Herdr tabs are flattened: a tab with a single pane shows as that terminal, and only a tab with split panes becomes a nested group.

| Key | |
| --- | --- |
| `<CR>` / `o` | Open terminal / toggle space |
| `l` / `h` | Expand / collapse (or jump to parent) |
| `s` `<C-v>` / `S` `<C-s>` / `t` `<C-t>` | Open in vsplit / split / new tab |
| `T` | Open, taking over another `terminal attach` of that pane |
| `a` | Add a terminal to the space under the cursor (on the root line: add a space) |
| `A` | Add a space |
| `r` | Rename |
| `d` | Close in Herdr (confirms) |
| `f` | Focus in Herdr's own UI |
| `C` | Connect to another server/profile |
| `z` / `Z` | Collapse all |
| `R` / `u` | Refresh |
| `q` | Close tree |
| `?` | Help |

Status: `●` working, `!` blocked, `✓` done, `○` idle. `↗` marks terminals attached in this Neovim.
Terminal buffers of panes closed in Herdr are removed automatically.

## Picker

Spaces with their terminals nested underneath, fuzzy-matched on space, name, agent, status and directory.
The preview shows a terminal's current screen with colors (`pane.read`); for a space it lists its terminals.
Stays live while open.

| Key | |
| --- | --- |
| `<CR>` | Open terminal (on a space: its focused terminal) |
| `<C-v>` / `<C-s>` / `<C-t>` | Open in vsplit / split / tab |
| `<A-f>` | Focus in Herdr's own UI |

## Behavior to know about

- Herdr allows one `terminal attach` client per pane. Opening a pane that is attached elsewhere offers to take it over. Herdr's own UI (`herdr` / `herdr --remote`) does not count and can show the same pane at the same time.
- While attached, Herdr resizes the pane to the Neovim window's size and keeps it at that size until you detach.
- Closing the terminal buffer detaches. `Ctrl-B q` inside the terminal also detaches (Herdr's own detach keys).
- In the `ssh` attach fallback, some SSH servers (for example Coder workspaces) keep a remote command running after its local ssh client is killed. herdr-nvim records each remote attach's PID and hangs it up when the buffer closes and on exit, so panes never stay attached behind your back.
- In the `ssh` fallback each open terminal is one SSH session on the shared connection; OpenSSH servers allow 10 by default (`MaxSessions`).

## User events

`User HerdrAttach` and `User HerdrDetach` fire with `data = { buf, pane_id }`.

## Development

```sh
# Read-only smoke test against a live server
HERDR_REMOTE=devbox nvim --headless -u NONE -l tests/smoke_api.lua

# Try the plugin in isolation
HERDR_REMOTE=devbox nvim -u tests/minimal_init.lua
```

Format with `stylua lua plugin tests`.
