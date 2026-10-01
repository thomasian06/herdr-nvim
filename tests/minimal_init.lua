local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/herdr.lua")
vim.o.termguicolors = true
local remote = os.getenv("HERDR_REMOTE")
require("herdr").setup({ remote = remote ~= "" and remote or nil, session = os.getenv("HERDR_SESSION") or "main" })
