local M = {}

---@class herdr.Config
M.defaults = {
    -- SSH target running the Herdr server (e.g. "devbox"). nil = local server.
    remote = nil,
    -- Herdr session name.
    session = "main",
    -- Named connections offered by `:Herdr connect`, e.g.
    -- { { name = "devbox", remote = "devbox", session = "main" } }.
    -- Herdr's saved machines and profiles saved with `:Herdr save` are offered too.
    profiles = {},
    -- Folder on the Herdr server where new spaces start (`~` is the server's
    -- home). Profiles can set their own `projects_dir`. nil: Herdr's default
    -- (follow the last focused space).
    projects_dir = nil,
    -- Start the Herdr server when it is not running: "ask" | true | false.
    auto_start = "ask",
    -- How terminals attach to a remote server:
    --   "auto"  local `herdr` through the forwarded socket when it is installed
    --           and protocol-compatible, else run `herdr` on the remote
    --   "ssh"   always run `herdr terminal attach` on the remote
    remote_attach = "auto",
    -- Default keymaps. Set any to false (or `keymaps = false`) to disable.
    keymaps = {
        toggle = "<leader>aa", -- toggle the herdr tree
        pick = "<leader>ap", -- spaces/agents picker
        connect = "<leader>ac", -- connect to a server/profile
        new_space = "<leader>an", -- create a space and open its terminal
        compose = "<leader>ai", -- compose input for an agent (the current/last terminal, else pick)
    },
    -- Herdr binary for local mode.
    herdr_bin = "herdr",
    -- Directories prepended to PATH on the remote before running `herdr`.
    remote_path = { "$HOME/.local/bin" },
    -- Tree window. Unset values are borrowed from your file explorer
    -- (snacks.nvim explorer or neo-tree), falling back to snacks' defaults.
    tree = {
        width = nil,
        position = nil, -- "left" | "right"
        icons = nil, -- e.g. { agent = "A ", shell = "$ " }
        indent = nil, -- e.g. { vertical = "| ", middle = "|-", last = "`-" }
        scrolloff = 4, -- native scroll margin; do not inherit cursor-centering settings
        -- Keys in the tree: lhs = action (false disables a default). Actions:
        -- open, expand, collapse, vsplit, split, tab, takeover, open_all, add,
        -- add_space, rename, delete, move_up, move_down, focus, connect,
        -- collapse_all, refresh, close, help.
        keys = {
            ["<CR>"] = "open",
            ["o"] = "open",
            ["<2-LeftMouse>"] = "open",
            ["l"] = "expand",
            ["h"] = "collapse",
            ["s"] = "vsplit",
            ["<C-v>"] = "vsplit",
            ["S"] = "split",
            ["<C-s>"] = "split",
            ["t"] = "tab",
            ["<C-t>"] = "tab",
            ["T"] = "takeover",
            ["O"] = "open_all",
            ["a"] = "add",
            ["A"] = "add_space",
            ["r"] = "rename",
            ["d"] = "delete",
            ["K"] = "move_up",
            ["J"] = "move_down",
            ["f"] = "focus",
            ["C"] = "connect",
            ["z"] = "collapse_all",
            ["Z"] = "collapse_all",
            ["R"] = "refresh",
            ["u"] = "refresh",
            ["q"] = "close",
            ["?"] = "help",
            ["g?"] = "help",
        },
    },
    -- Keys in the snacks.nvim picker (insert and normal mode). Actions:
    -- vsplit, split, tab, focus. <CR> opens, <Tab> marks several.
    picker = {
        keys = {
            ["<c-v>"] = "vsplit",
            ["<c-s>"] = "split",
            ["<c-t>"] = "tab",
            ["<a-f>"] = "focus",
        },
    },
    -- Status glyphs: "herdr" follows Herdr's [ui] status_indicators; or "dots" /
    -- "symbols".
    status_style = "herdr",
    -- Finished agents show as done (teal ●) until seen, then idle (green ○).
    -- "local": viewing one in Neovim marks it seen here only. "herdr": also
    -- mark it seen in Herdr (this moves Herdr's focus to it).
    mark_seen = "local",
    -- Notifications when an agent finishes or needs input (Herdr's rules and sounds).
    notify = {
        enabled = true,
        -- "herdr": follow Herdr's [ui.sound] settings; true: always; false: never.
        sound = "herdr",
        -- Also show a vim.notify message.
        message = true,
        on = { done = true, blocked = true },
    },
    -- Herdr terminal buffers.
    terminal = {
        -- Enter terminal mode when entering a herdr terminal window.
        auto_insert = true,
        -- Show agent, name, status and space in each terminal window's winbar.
        winbar = true,
        -- Keys in herdr terminal buffers: lhs = action (false disables a
        -- default; { "action", mode = ... } sets the modes). Actions:
        --   normal_mode (t)            leave terminal mode; the key is not sent
        --                              to the agent (give agents that interrupt
        --                              on <Esc> another key, see the README)
        --   nav_left/down/up/right (t) move to the neighboring window (through
        --                              vim-tmux-navigator / smart-splits.nvim)
        --   history_wheel (n), history_half_page, history_page, history_line,
        --   history_up, history_top, history_search, history_search_back (n)
        --                              open the cached history and scroll/search
        --   compose (n)                compose input (also global <leader>ai)
        keys = {
            ["<Esc>"] = "normal_mode",
            ["<C-h>"] = "nav_left",
            ["<C-j>"] = "nav_down",
            ["<C-k>"] = "nav_up",
            ["<C-l>"] = "nav_right",
            ["<ScrollWheelUp>"] = "history_wheel",
            ["<C-u>"] = "history_half_page",
            ["<C-b>"] = "history_page",
            ["<PageUp>"] = "history_page",
            ["<C-y>"] = "history_line",
            ["k"] = "history_up",
            ["gg"] = "history_top",
            ["/"] = "history_search",
            ["?"] = "history_search_back",
        },
    },
    -- Local, cached terminal history (opened by the history_* terminal keys).
    history = {
        enabled = true,
        -- Most lines kept per terminal.
        limit = 100000,
        -- Keys in the history view. Actions: live_insert (back to the live
        -- terminal, typing), live (back to it), compose.
        keys = {
            ["i"] = "live_insert",
            ["a"] = "live_insert",
            ["I"] = "live_insert",
            ["A"] = "live_insert",
            ["q"] = "live",
            ["<Esc>"] = "live",
        },
    },
    -- Compose split (<leader>ai): edit an agent's input with full Neovim editing.
    compose = {
        height = 8,
        -- Actions: send (as a prompt), paste (into the agent's input without
        -- sending), close (keep the draft).
        keys = {
            ["<CR>"] = "send",
            ["<C-s>"] = { "send", mode = { "n", "i" } },
            ["<C-g>"] = { "paste", mode = { "n", "i" } },
            ["q"] = "close",
        },
    },
    -- Debounce for re-fetching the session snapshot after server events (ms).
    refresh_debounce_ms = 80,
}

---@type herdr.Config
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
