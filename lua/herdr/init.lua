local config = require("herdr.config")

local M = {}

local function set_keymaps()
    local keys = config.options.keymaps
    if not keys then
        return
    end
    local defs = {
        { keys.toggle, "<cmd>Herdr toggle<cr>", "Herdr tree" },
        { keys.pick, "<cmd>Herdr pick<cr>", "Herdr pick space/agent" },
        { keys.connect, "<cmd>Herdr connect<cr>", "Herdr connect" },
        { keys.new_space, "<cmd>Herdr new-space<cr>", "Herdr new space" },
    }
    for _, d in ipairs(defs) do
        if d[1] then
            vim.keymap.set("n", d[1], d[2], { desc = d[3], silent = true })
        end
    end
    -- Label the shared prefix in which-key when both keys share one (e.g. <leader>a).
    local a, b = keys.toggle, keys.pick
    if not (a and b and #a == #b and #a > 1 and a:sub(1, -2) == b:sub(1, -2)) then
        return
    end
    local function label()
        local wk = package.loaded["which-key"]
        if wk and wk.add then
            wk.add({ { a:sub(1, -2), group = "herdr" } })
            return true
        end
    end
    -- Don't force-load which-key; label it now if loaded, else once lazy.nvim is done.
    if not label() then
        vim.api.nvim_create_autocmd("User", { pattern = "VeryLazy", once = true, callback = label })
    end
end

function M.setup(opts)
    config.setup(opts)
    set_keymaps()
    require("herdr.notify").setup()
    require("herdr.history").setup()
    -- Nothing connects on its own, except a trusted project file
    -- (.herdr-nvim.json) at startup or after :cd while disconnected.
    local group = vim.api.nvim_create_augroup("herdr_autoconnect", { clear = true })
    local function autoconnect()
        require("herdr.connection").autoconnect()
    end
    if vim.v.vim_did_enter == 1 then
        vim.schedule(autoconnect)
    else
        vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = autoconnect })
    end
    vim.api.nvim_create_autocmd("DirChanged", { group = group, pattern = "global", callback = autoconnect })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("herdr_transport", { clear = true }),
        callback = function()
            if package.loaded["herdr.terminal"] then
                require("herdr.terminal").detach_all()
            end
            require("herdr.transport").shutdown()
        end,
    })
end

--- Toggle the herdr tree.
function M.toggle()
    require("herdr.tree").toggle()
end

function M.open_tree()
    require("herdr.tree").open()
end

function M.refresh()
    require("herdr.state").refresh()
end

--- Open a pane by id (e.g. "w1:p1"). A pane created moments ago may not be in
--- the snapshot yet: refresh once before giving up.
function M.open(pane_id, opts)
    local connection = require("herdr.connection")
    if not connection.active then
        return connection.with_connection(function()
            M.open(pane_id, opts)
        end)
    end
    local state = require("herdr.state")
    state.when_snapshot(function()
        if state.pane(pane_id) then
            return require("herdr.terminal").open(pane_id, opts)
        end
        local off
        off = state.on_change(function(snap)
            if snap then
                off()
                vim.schedule(function()
                    require("herdr.terminal").open(pane_id, opts) -- warns if still unknown
                end)
            end
        end)
        state.refresh()
    end)
end

--- Open every agent in the session, tiled in a new tab.
function M.agents()
    if not require("herdr.connection").active then
        return require("herdr.connection").with_connection(M.agents)
    end
    local state = require("herdr.state")
    local function go()
        local panes = {}
        for _, p in ipairs(state.snapshot.panes or {}) do
            if p.agent then
                panes[#panes + 1] = p
            end
        end
        require("herdr.terminal").open_many(panes)
    end
    if state.snapshot then
        return go()
    end
    local off
    off = state.on_change(function(snap, err)
        if snap then
            off()
            vim.schedule(go)
        elseif err then
            off()
            vim.notify("herdr: " .. err, vim.log.levels.ERROR)
        end
    end)
    state.start()
end

--- Create a space (asking for a name unless given) and open its terminal.
function M.new_space(name)
    require("herdr.tree").add_space(name)
end

--- Pick a space/agent (snacks.picker with live preview; vim.ui.select fallback).
function M.pick(opts)
    require("herdr.picker").open(opts)
end

return M
