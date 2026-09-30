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
  remote = nil, -- optional SSH target offered as a profile (nothing connects automatically)
  session = "main", -- session for `remote`
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
  notify = {
    enabled = true,
    sound = "herdr", -- follow Herdr's [ui.sound] settings; true: always; false: never
    message = true, -- also show a vim.notify message
    on = { done = true, blocked = true },
  },
  terminal = {
    double_esc = true, -- double-tap <Esc> leaves terminal mode; a single <Esc> reaches the agent
    auto_insert = true, -- entering a herdr terminal window enters terminal mode
    winbar = true, -- status, agent, name and space above each terminal
    -- navigate windows from terminal mode (vim-tmux-navigator / smart-splits aware); false to disable
    navigation = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
  },
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
| `:Herdr agents` | Open every agent in the session, tiled in a new tab |
| `:Herdr connect [profile\|host[:session]]` | Connect to a server; without an argument, pick one |
| `:Herdr disconnect` | Disconnect |
| `:Herdr save [name]` | Save the current connection as a profile |
| `:Herdr forget <name>` | Remove a saved profile |

## Connections

Nothing connects on its own: open the tree and press `C`, or use `:Herdr connect` (`<leader>ac`).
The picker offers:

- the current and last-used connection, and local Herdr
- `profiles` (and `remote`/`session`) from `setup()`
- Herdr's own saved machines (`herdr machine add ...`), so machines set up for Herdr work here too
- profiles saved with `:Herdr save`
- **New connection…**, which asks for an SSH target and session, then offers to save it

Saved profiles live in `stdpath("data")/herdr-nvim/connections.json`.
Switching detaches and closes the previous server's terminals.

### Project file

To connect automatically in a project, put a `.herdr-nvim.json` in it (or any parent directory):

```json
{ "remote": "devbox", "session": "main" }
```

or refer to a profile: `{ "profile": "devbox" }`.

herdr-nvim connects when Neovim starts in that directory, or when you `:cd` into it while disconnected.
It never switches away from an active connection; it tells you instead.
The first time (and after the file changes) it asks: **Trust and connect**, **Not now**, or **Never**.
The choice is kept in Neovim's trust database, the same one `'exrc'` and `vim.secure` use.
SSH targets that could be read as `ssh` options (starting with `-`) are rejected.

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
| `O` | Open every terminal under the cursor, tiled in a new tab (on the root line: every agent) |
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
| `<Tab>` then `<CR>` | Mark several spaces/terminals and open them all, tiled in a new tab |
| `<C-v>` / `<C-s>` / `<C-t>` | Open in vsplit / split / tab |
| `<A-f>` | Focus in Herdr's own UI |

## Notifications

Like Herdr itself, herdr-nvim rings when an agent needs input (becomes blocked) or finishes (goes from working to idle), and shows a notification such as "fix-login (codex) is done".
It stays quiet for the agent in the window you are looking at while Neovim has focus.
The sounds are Herdr's own, and Herdr's `[ui.sound]` settings in `~/.config/herdr/config.toml` (`enabled`, `path`, `done_path`, `request_path`) and `HERDR_DISABLE_SOUND` apply.
Notifications work whenever you are connected, even with the tree closed.

## bufferline.nvim

To keep buffer tabs to the right of the tree (like with neo-tree or snacks' explorer), add an offset:

```lua
{
  "akinsho/bufferline.nvim",
  optional = true,
  opts = function(_, opts)
    opts.options = opts.options or {}
    opts.options.offsets = opts.options.offsets or {}
    table.insert(opts.options.offsets, { filetype = "herdr", text = "Herdr", highlight = "Directory", text_align = "left" })
  end,
}
```

## Working in agent terminals

- Double-tap `<Esc>` to leave terminal mode (a single `<Esc>` still reaches the agent, e.g. to interrupt it). `<C-\><C-n>` works too.
- `<C-h/j/k/l>` move between windows straight from terminal mode, and entering a herdr terminal window puts you back into terminal mode, so you can hop between agents and type without leaving terminal mode.
  With [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) or [smart-splits.nvim](https://github.com/mrjones2014/smart-splits.nvim) installed, the edges continue into tmux (or WezTerm/Kitty) panes.
  Agents no longer receive those keys; set `terminal.navigation = false` (or pick other keys) if one needs them.
- Each terminal window's winbar shows its status, agent, name and space, so a grid of agents stays readable.

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
