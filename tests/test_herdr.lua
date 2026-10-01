-- End to end against a real, isolated Herdr server ($HERDR_BIN or `herdr`).
local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.child()
local server

local T = MiniTest.new_set({
    hooks = {
        pre_once = function()
            server = H.start_herdr()
        end,
        pre_case = function()
            child.setup()
            child.lua(
                [[
                local bin, projects = ...
                require("herdr").setup({
                    herdr_bin = bin,
                    projects_dir = projects,
                    notify = { sound = false, message = false },
                    auto_start = false,
                })
                require("herdr.connection").switch({ session = "t" })
            ]],
                { server.bin, server.dir }
            )
            H.wait_child(child, [[require("herdr.state").snapshot ~= nil]], 10000)
        end,
        post_case = function()
            child.lua([[require("herdr.connection").disconnect()]])
        end,
        post_once = function()
            child.stop()
            if server then
                server.stop()
            end
        end,
    },
})

local function snapshot()
    return server.request("session.snapshot").snapshot
end

local function tree_lines()
    return child.lua_get([[vim.api.nvim_buf_get_lines(vim.fn.bufnr("herdr://tree"), 0, -1, false)]])
end

--- Put the tree cursor on the first line containing `text`.
local function tree_goto(text)
    child.cmd("Herdr")
    H.wait_child(child, ("vim.fn.search(%q, 'cw') > 0"):format(vim.pesc(text):gsub("%%", "\\")))
end

local function attached(pane_id)
    return child.lua_get([[require("herdr.terminal").attached_panes()[...] ~= nil]], { pane_id })
end

T["tree lists spaces and terminals"] = function()
    server.space("alpha")
    server.space("beta")
    child.lua([[require("herdr.state").refresh()]])
    child.cmd("Herdr")
    H.wait_child(child, [[vim.fn.search("beta", "cw") > 0]])
    local text = table.concat(tree_lines(), "\n")
    eq(text:find("local:t", 1, true) ~= nil, true)
    eq(text:find("alpha", 1, true) ~= nil, true)
    eq(text:find("beta", 1, true) ~= nil, true)
end

T["a creates a terminal in the space and opens it"] = function()
    server.space("gamma")
    child.lua([[require("herdr.state").refresh()]])
    child.lua([[vim.ui.input = function(_, cb) cb("added") end]])
    tree_goto("gamma")
    child.type_keys("a")
    local tab
    vim.wait(5000, function()
        for _, t in ipairs(snapshot().tabs) do
            if t.label == "added" then
                tab = t
                return true
            end
        end
    end, 100)
    eq(tab ~= nil, true)
    H.wait_child(child, [[vim.b.herdr_terminal_id ~= nil]])
end

T["typing in an attached terminal reaches the pane"] = function()
    local pane = server.space("delta").root_pane.pane_id
    child.lua([[require("herdr.state").refresh()]])
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    vim.wait(500)
    child.lua([[vim.api.nvim_chan_send(vim.bo.channel, "echo marker-$((40+2))\r")]])
    server.wait_output(pane, "marker-42")
    H.wait_child(child, [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("marker%-42") ~= nil]])
end

T["history shows output that scrolled off the screen"] = function()
    local pane = server.space("epsilon").root_pane.pane_id
    server.request("pane.send_text", { pane_id = pane, text = "seq 1 300\n" })
    server.wait_output(pane, "300")
    child.lua([[require("herdr.state").refresh()]])
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    child.cmd("stopinsert")
    child.lua([[require("herdr.history").open("gg")]])
    H.wait_child(child, [[vim.b.herdr_history == true]])
    H.wait_child(child, [[vim.fn.search("^1$", "nw") > 0 and vim.fn.search("^300$", "nw") > 0]])
    -- i returns to the live terminal
    child.type_keys("i")
    H.wait_child(child, [[vim.b.herdr_terminal_id ~= nil]])
end

T["d closes a terminal"] = function()
    local created = server.space("zeta")
    local tab_id = created.tab.tab_id
    child.lua([[require("herdr.state").refresh()]])
    child.lua([[vim.fn.confirm = function() return 1 end]])
    tree_goto("zeta")
    child.type_keys("j") -- the space's terminal
    child.type_keys("d")
    local gone = vim.wait(5000, function()
        for _, t in ipairs(snapshot().tabs) do
            if t.tab_id == tab_id then
                return false
            end
        end
        return true
    end, 100)
    eq(gone, true)
end

T["opening a herdr:// buffer attaches its pane (Harpoon, :edit)"] = function()
    local pane = server.space("eta").root_pane.pane_id
    child.lua([[require("herdr.connection").disconnect()]])
    child.cmd("edit herdr://local:t/" .. pane .. "/eta")
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane), 10000)
    eq(child.lua_get([[require("herdr.connection").label(require("herdr.connection").active)]]), "local:t")
    eq(attached(pane), true)
end

T["a new space starts in projects_dir"] = function()
    child.lua([[require("herdr").new_space("theta")]])
    local cwd
    vim.wait(5000, function()
        local snap = snapshot()
        for _, w in ipairs(snap.workspaces) do
            if w.label == "theta" then
                for _, p in ipairs(snap.panes) do
                    if p.workspace_id == w.workspace_id then
                        cwd = p.cwd
                        return true
                    end
                end
            end
        end
    end, 100)
    eq(vim.uv.fs_realpath(cwd or ""), vim.uv.fs_realpath(server.dir))
end

T["picker lists spaces and terminals"] = function()
    server.space("iota")
    child.lua([[require("snacks").setup({ picker = { enabled = true } }); require("herdr.state").refresh()]])
    child.lua([[require("herdr").pick()]])
    -- The picker updates live, so the new space appears once the snapshot has it.
    H.wait_child(
        child,
        [[Snacks.picker.get()[1] ~= nil and vim.tbl_contains(vim.tbl_map(function(i) return i.name end, Snacks.picker.get()[1]:items()), "iota")]]
    )
    child.lua([[Snacks.picker.get()[1]:close()]])
end

T["disconnect detaches everything"] = function()
    local pane = server.space("kappa").root_pane.pane_id
    child.lua([[require("herdr.state").refresh()]])
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    child.lua([[require("herdr.connection").disconnect()]])
    eq(child.lua_get([[vim.tbl_count(require("herdr.terminal").attached_panes())]]), 0)
    eq(child.lua_get([[require("herdr.connection").active]]), vim.NIL)
end

return T
