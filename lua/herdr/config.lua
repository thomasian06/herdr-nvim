local M = {}

---@class herdr.Config
M.defaults = {
    -- SSH target running the Herdr server (e.g. "devbox"). nil = local server.
    remote = nil,
    -- Herdr session name.
    session = "main",
    -- Default keymaps. Set any to false (or `keymaps = false`) to disable.
    keymaps = {
        toggle = "<leader>aa", -- toggle the herdr tree
        pick = "<leader>ap", -- spaces/agents picker
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
    -- Debounce for re-fetching the session snapshot after server events (ms).
    refresh_debounce_ms = 80,
}

---@type herdr.Config
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
