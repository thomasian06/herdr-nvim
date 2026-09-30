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
    connect = function(args)
        local connection = require("herdr.connection")
        if not args[1] then
            return connection.pick()
        end
        connection.resolve(args[1], connection.switch)
    end,
    disconnect = function()
        require("herdr.connection").disconnect()
    end,
    save = function(args)
        local connection = require("herdr.connection")
        local name = args[1] or connection.current().remote or "local"
        connection.save(name)
        connection._current_name = name
        vim.notify("herdr: saved profile '" .. name .. "' (" .. connection.label(connection.current()) .. ")")
    end,
    forget = function(args)
        if not args[1] then
            return vim.notify("usage: :Herdr forget <profile>", vim.log.levels.WARN)
        end
        local removed = require("herdr.connection").forget(args[1])
        vim.notify("herdr: " .. (removed and "forgot" or "no saved profile named") .. " '" .. args[1] .. "'")
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
        if words[2] == "connect" or words[2] == "forget" then
            return vim.tbl_filter(function(n)
                return n:find(arglead, 1, true) == 1
            end, require("herdr.connection").saved_names())
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
