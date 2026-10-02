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

T["history follows the window width, without duplicates"] = function()
    local pane = server.space("widths").root_pane.pane_id
    child.lua([[require("herdr.state").refresh()]])
    child.cmd("vsplit | vertical resize 50")
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    vim.wait(500) -- the pane takes the window's width
    -- 105-column lines while the pane is 50 wide: Herdr wraps them on screen
    local cmd = 'for i in $(seq 1 60); do printf "L%03d %0100d\\n" $i 0; done\n'
    server.request("pane.send_text", { pane_id = pane, text = cmd })
    server.wait_output(pane, "L060")
    child.cmd("stopinsert")
    child.lua([[require("herdr.history").open("gg")]])
    H.wait_child(child, [[vim.b.herdr_history == true and vim.fn.search("^L060", "nw") > 0]])
    local built = [[require("herdr.history")._built[vim.api.nvim_get_current_buf()] ]]
    eq(child.lua_get(built .. ".width"), 50)
    -- Fullscreen: rebuilt at the new width, each line once and on one row.
    child.cmd("only")
    H.wait_child(child, ("(%s or {}).width == vim.api.nvim_win_get_width(0)"):format(built))
    H.wait_child(child, [[vim.fn.search("^L060 0\\+$", "nw") > 0]])
    local lines = child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
    local seen, gaps = {}, 0
    for _, l in ipairs(lines) do
        local n = l:match("^L(%d%d%d) 0+%s*$")
        if n then
            seen[#seen + 1] = n
        end
        gaps = gaps + (l:find("not loaded", 1, true) and 1 or 0)
    end
    eq({ #seen, seen[1], seen[60], gaps }, { 60, "001", "060", 0 })
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

T["K and J reorder spaces and terminals"] = function()
    local created = server.space("reorder")
    local ws_id = created.workspace.workspace_id
    local second = server.request("tab.create", { workspace_id = ws_id, label = "second", focus = false }).tab.tab_id
    local function spaces()
        return vim.tbl_map(function(ws)
            return ws.workspace_id
        end, snapshot().workspaces)
    end
    local function tabs()
        local ids = {}
        for _, tab in ipairs(snapshot().tabs) do
            if tab.workspace_id == ws_id then
                ids[#ids + 1] = tab.tab_id
            end
        end
        return ids
    end
    --- Poll Herdr until fn() is true (a deadline, as each poll waits on a request).
    local function eventually(fn)
        local deadline = vim.uv.hrtime() + 5e9
        while vim.uv.hrtime() < deadline do
            if fn() then
                return true
            end
            vim.wait(100)
        end
        return fn()
    end
    local at = vim.fn.index(spaces(), ws_id)
    eq(tabs(), { created.tab.tab_id, second })
    child.lua([[require("herdr.state").refresh()]])

    -- K, then J at once: the space moves up and back, and the cursor stays on it.
    tree_goto("reorder")
    child.type_keys("K")
    child.type_keys("J")
    eq(
        eventually(function()
            return vim.fn.index(spaces(), ws_id) == at
        end),
        true
    )
    child.type_keys("K")
    eq(
        eventually(function()
            return vim.fn.index(spaces(), ws_id) == at - 1
        end),
        true
    )
    H.wait_child(child, [[vim.api.nvim_get_current_line():find("reorder", 1, true) ~= nil]])

    -- A terminal moves among its space's terminals, and the cursor follows it.
    -- (The tree is still open: search in it rather than toggling it.)
    H.wait_child(child, [[vim.fn.search("second", "cw") > 0]])
    child.type_keys("K")
    eq(
        eventually(function()
            return tabs()[1] == second
        end),
        true
    )
    H.wait_child(child, [[vim.api.nvim_get_current_line():find("second", 1, true) ~= nil]])
    -- Already first: K does nothing.
    child.type_keys("K")
    vim.wait(300)
    eq(tabs()[1], second)
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

T["<leader>ai composes input in a buffer and sends it"] = function()
    local pane = server.space("lambda").root_pane.pane_id
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    child.cmd("stopinsert")
    child.type_keys(" ai")
    H.wait_child(child, [[vim.api.nvim_buf_get_name(0):find("herdr%-compose://") ~= nil]])
    eq(child.fn.mode(), "i")
    child.type_keys("echo composed-$((1+1))", "<C-s>")
    server.wait_output(pane, "composed-2")
    H.wait_child(child, [[vim.b.herdr_terminal_id ~= nil]]) -- back in the terminal
    eq(#child.api.nvim_tabpage_list_wins(0), 1) -- compose split closed
end

--- Make a shell pane report itself as an agent (like Herdr's agent integrations).
local function report_agent(pane, state_)
    server.request("pane.report_agent", { pane_id = pane, source = "herdr-nvim-test", agent = "pi", state = state_ })
end

T["compose sends to an agent with agent.prompt"] = function()
    local pane = server.space("nu").root_pane.pane_id
    report_agent(pane, "idle")
    child.lua([[
        _G.methods = {}
        local api = require("herdr.api")
        local request = api.request
        api.request = function(method, ...) table.insert(_G.methods, method); return request(method, ...) end
        require("herdr.state").refresh()
    ]])
    H.wait_child(child, ([[(require("herdr.state").pane(%q) or {}).agent == "pi"]]):format(pane))
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    child.cmd("stopinsert")
    child.type_keys(" ai", "echo prompted-$((2+3))", "<C-s>")
    server.wait_output(pane, "prompted-5")
    eq(vim.tbl_contains(child.lua_get("_G.methods"), "agent.prompt"), true)
end

T["statuses: done until seen, with a notification"] = function()
    local pane = server.space("xi").root_pane.pane_id
    child.lua([[
        _G.sounds = {}
        require("herdr.notify").play = function(kind) table.insert(_G.sounds, kind) end
    ]])
    report_agent(pane, "working")
    H.wait_child(
        child,
        ([[require("herdr.state").pane_status(require("herdr.state").pane(%q) or {}) == "working"]]):format(pane)
    )
    report_agent(pane, "idle") -- finished, and nobody has looked at it yet
    H.wait_child(
        child,
        ([[require("herdr.state").pane_status(require("herdr.state").pane(%q) or {}) == "done"]]):format(pane)
    )
    H.wait_child(child, [[vim.tbl_contains(_G.sounds, "done")]])
    eq(
        child.lua_get(
            [[require("herdr.state").workspace_status(require("herdr.state").pane(...).workspace_id)]],
            { pane }
        ),
        "done"
    )
    -- Viewing its terminal marks it seen.
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(
        child,
        ([[require("herdr.state").pane_status(require("herdr.state").pane(%q)) == "idle"]]):format(pane)
    )
end

T["a compose draft survives closing"] = function()
    local pane = server.space("mu").root_pane.pane_id
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    child.cmd("stopinsert")
    child.type_keys(" ai", "half a thought", "<Esc>", "q")
    H.wait_child(child, [[vim.b.herdr_terminal_id ~= nil]])
    child.cmd("stopinsert")
    child.type_keys(" ai")
    H.wait_child(child, [[vim.api.nvim_buf_get_name(0):find("herdr%-compose://") ~= nil]])
    eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { "half a thought" })
end

T["<leader>ai from a code window composes for the last terminal"] = function()
    local pane = server.space("omicron").root_pane.pane_id
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    child.cmd("stopinsert")
    child.cmd("vsplit | enew") -- a "code" window, terminal still visible
    child.type_keys(" ai")
    H.wait_child(child, [[vim.api.nvim_buf_get_name(0):find("herdr%-compose://") ~= nil]])
    eq(child.lua_get("vim.b.herdr_pane_id"), pane)
end

T["<leader>ai with no terminal open asks which agent"] = function()
    local pane = server.space("pi-space").root_pane.pane_id
    child.lua([[
        require("herdr.state").refresh()
        vim.ui.select = function(items, _, cb)
            for _, p in ipairs(items) do
                if p.pane_id == _G.want then return cb(p) end
            end
        end
    ]])
    child.lua("_G.want = ...", { pane })
    H.wait_child(child, ([[require("herdr.state").pane(%q) ~= nil]]):format(pane))
    child.type_keys(" ai")
    H.wait_child(child, [[vim.api.nvim_buf_get_name(0):find("herdr%-compose://") ~= nil]])
    eq(child.lua_get("vim.b.herdr_pane_id"), pane)
end

T["a restarted server is reconnected and terminals reattach"] = function()
    local pane = server.space("sigma").root_pane.pane_id
    child.lua([[require("herdr").open(...)]], { pane })
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane))
    child.lua([[
        _G.events = {}
        for _, e in ipairs({ "HerdrDisconnected", "HerdrReconnected" }) do
            vim.api.nvim_create_autocmd("User", { pattern = e, callback = function() table.insert(_G.events, e) end })
        end
    ]])
    server.restart()
    server.space("rho") -- something new to see once reconnected
    child.lua([[require("herdr.state").refresh()]]) -- next request notices the drop
    H.wait_child(child, [[vim.tbl_contains(_G.events, "HerdrReconnected")]], 20000)
    eq(child.lua_get("_G.events[1]"), "HerdrDisconnected")
    H.wait_child(
        child,
        [[(function()
        for _, w in ipairs((require("herdr.state").snapshot or {}).workspaces or {}) do
            if w.label == "rho" then return true end
        end
        return false
    end)()]],
        10000
    )
    -- Herdr restores panes after a restart; the open terminal is attached again.
    H.wait_child(child, ([[require("herdr.terminal").attached_panes()[%q] ~= nil]]):format(pane), 10000)
    vim.wait(500)
    child.lua([[vim.api.nvim_chan_send(vim.bo.channel, "echo back-$((6*7))\r")]])
    server.wait_output(pane, "back-42")
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
