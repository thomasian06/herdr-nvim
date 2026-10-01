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

-- Keep only Neovim's own runtime dirs (incl. bundled treesitter parsers),
-- dropping any user config or installed plugins.
local rtp = { root }
local vim_dir = vim.env.VIM or ""
for _, dir in ipairs(vim.opt.rtp:get()) do
    if
        dir == vim.env.VIMRUNTIME
        or (vim_dir ~= "" and dir:sub(1, #vim_dir) == vim_dir)
        or dir:find("/lib/nvim", 1, true)
    then
        rtp[#rtp + 1] = dir
    end
end
vim.opt.rtp = rtp
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
