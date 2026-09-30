-- Offline check: every module loads, setup() works, keymaps and the command
-- exist, and the tree renders without a server.
-- Usage: nvim --headless -u NONE -l tests/load.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.g.mapleader = " "
vim.cmd("runtime plugin/herdr.lua")

local failures = 0
local function check(name, ok, detail)
    io.stdout:write((ok and "ok   " or "FAIL ") .. name .. (detail and ("  " .. detail) or "") .. "\n")
    if not ok then
        failures = failures + 1
    end
end

for _, mod in ipairs({
    "herdr",
    "herdr.config",
    "herdr.api",
    "herdr.transport",
    "herdr.state",
    "herdr.style",
    "herdr.terminal",
    "herdr.tree",
    "herdr.picker",
}) do
    local ok, err = pcall(require, mod)
    check("require " .. mod, ok, not ok and tostring(err) or nil)
end

require("herdr").setup({ herdr_bin = "herdr-nvim-test-missing-binary" })
check("command :Herdr", vim.fn.exists(":Herdr") == 2)
check("keymap <leader>aa", vim.fn.maparg("<leader>aa", "n") ~= "")
check("keymap <leader>ap", vim.fn.maparg("<leader>ap", "n") ~= "")

require("herdr").setup({ keymaps = false })
vim.keymap.del("n", "<leader>aa")
vim.keymap.del("n", "<leader>ap")
require("herdr").setup({ keymaps = false })
check("keymaps = false", vim.fn.maparg("<leader>aa", "n") == "")

-- The tree opens and shows an error (no server) instead of crashing.
require("herdr.config").setup({ herdr_bin = "herdr-nvim-test-missing-binary" })
local ok, err = pcall(vim.cmd, "Herdr toggle")
check("open tree", ok, not ok and tostring(err) or nil)
vim.wait(3000, function()
    return require("herdr.state").error ~= nil
end, 50)
local lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr("herdr://tree"), 0, -1, false)
check(
    "tree shows missing-herdr error",
    table.concat(lines, "\n"):find("not found", 1, true) ~= nil,
    table.concat(lines, " | ")
)

os.exit(failures == 0 and 0 or 1)
