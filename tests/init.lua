-- Init file for test Neovim instances (the runner and child instances).
-- Loads the plugin and the pinned test dependencies from .tests/deps, and
-- isolates config/data/state so tests never see (or touch) a real setup.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

if not vim.env.HERDR_NVIM_TEST_HOME then
    local home = vim.fn.tempname()
    vim.env.HERDR_NVIM_TEST_HOME = home
    for _, kind in ipairs({ "CONFIG", "DATA", "STATE", "CACHE" }) do
        local dir = home .. "/" .. kind:lower()
        vim.fn.mkdir(dir, "p")
        vim.env["XDG_" .. kind .. "_HOME"] = dir
    end
end
vim.env.HERDR_DISABLE_SOUND = "1"

vim.opt.rtp = { root, vim.env.VIMRUNTIME }
for _, dep in ipairs(vim.fn.glob(root .. "/.tests/deps/*", false, true)) do
    vim.opt.rtp:append(dep)
end
vim.opt.packpath = {}
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.g.mapleader = " "

vim.cmd("runtime plugin/herdr.lua")
if pcall(require, "mini.test") then
    require("mini.test").setup()
end
