local M = {}

--- vim.ui.input for quick prompts: a single <Esc> or <C-c> cancels.
---
--- snacks.nvim's input (LazyVim's vim.ui.input) normally takes <Esc> to mean
--- "leave insert mode" and needs a second <Esc> to cancel. For short prompts
--- like naming a new terminal, one keypress should cancel, like neo-tree's
--- prompts. Other vim.ui.input providers ignore the extra `win` option.
---@param opts table vim.ui.input options
---@param on_confirm fun(input: string?)
function M.input(opts, on_confirm)
    local cancel = { "cmp_close", "cancel" }
    opts = vim.tbl_deep_extend("force", {
        win = {
            keys = {
                i_esc = { "<esc>", cancel, mode = "i", expr = true },
                i_ctrl_c = { "<c-c>", cancel, mode = "i", expr = true },
            },
        },
    }, opts or {})
    local done = false
    vim.ui.input(opts, function(input)
        if done then
            return
        end
        done = true
        on_confirm(input)
    end)
end

return M
