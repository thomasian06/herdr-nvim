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
    },
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
        -- Double-tap <Esc> to leave terminal mode; a single <Esc> still reaches the agent.
        double_esc = true,
        -- Enter terminal mode when entering a herdr terminal window.
        auto_insert = true,
        -- Show agent, name, status and space in each terminal window's winbar.
        winbar = true,
        -- Navigate windows straight from terminal mode with these keys (false to
        -- disable, e.g. if an agent needs them). Uses vim-tmux-navigator or
        -- smart-splits.nvim when installed (so edges continue into tmux panes),
        -- else plain window moves.
        navigation = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
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
