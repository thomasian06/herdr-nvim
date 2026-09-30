if vim.g.loaded_herdr then
    return
end
vim.g.loaded_herdr = true

local function toggle()
    require("herdr").toggle()
end

local subcommands = {
    toggle = toggle,
    tree = toggle,
    pick = function()
        require("herdr").pick()
    end,
    open = function(args)
        if not args[1] then
            return vim.notify("usage: :Herdr open <pane_id>", vim.log.levels.WARN)
        end
        require("herdr").open(args[1])
    end,
    refresh = function()
        require("herdr").refresh()
    end,
}

vim.api.nvim_create_user_command("Herdr", function(cmd)
    local args = vim.split(vim.trim(cmd.args), "%s+", { trimempty = true })
    local name = table.remove(args, 1) or "toggle"
    local fn = subcommands[name]
    if not fn then
        return vim.notify("herdr: unknown subcommand " .. name, vim.log.levels.ERROR)
    end
    fn(args)
end, {
    nargs = "*",
    desc = "Herdr agent multiplexer",
    complete = function(arglead, line)
        local words = vim.split(line, "%s+")
        if #words <= 2 then
            return vim.tbl_filter(function(s)
                return s:find(arglead, 1, true) == 1
            end, vim.tbl_keys(subcommands))
        end
        if words[2] == "open" then
            local snap = require("herdr.state").snapshot
            local ids = {}
            for _, p in ipairs(snap and snap.panes or {}) do
                ids[#ids + 1] = p.pane_id
            end
            return ids
        end
        return {}
    end,
})
