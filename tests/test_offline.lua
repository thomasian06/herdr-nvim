-- UI behavior without a Herdr server, in a child Neovim.
local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality
local child = H.child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
        end,
        post_once = child.stop,
    },
})

local function tree_text()
    return table.concat(child.lua_get([[vim.api.nvim_buf_get_lines(vim.fn.bufnr("herdr://tree"), 0, -1, false)]]), "\n")
end

T["setup: default keymaps and command"] = function()
    child.lua([[require("herdr").setup({})]])
    eq(child.fn.exists(":Herdr"), 2)
    for _, lhs in ipairs({ "<leader>aa", "<leader>ap", "<leader>ac", "<leader>an", "<leader>ai" }) do
        eq(child.fn.maparg(lhs, "n") ~= "", true)
    end
end

T["setup: keymaps can be disabled"] = function()
    child.lua([[require("herdr").setup({ keymaps = false })]])
    eq(child.fn.maparg("<leader>aa", "n"), "")
end

T["keys are configurable: remap, disable, and help follows"] = function()
    child.lua([[require("herdr").setup({ tree = { keys = { x = "delete", d = false, ["?"] = "help" } } })]])
    child.cmd("Herdr")
    local maps = child.lua_get([[vim.tbl_map(function(m) return m.lhs end, vim.api.nvim_buf_get_keymap(0, "n"))]])
    eq(vim.tbl_contains(maps, "x"), true)
    eq(vim.tbl_contains(maps, "d"), false)
    eq(vim.tbl_contains(maps, "<CR>"), true) -- untouched defaults stay
    child.type_keys("?")
    local help = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    eq(help:find("x%s+close in herdr") ~= nil, true)
end

T["unknown key actions warn instead of failing"] = function()
    child.lua([[
        _G.msgs = {}
        vim.notify = function(m) table.insert(_G.msgs, m) end
        require("herdr").setup({ tree = { keys = { y = "no_such_action" } } })
    ]])
    child.cmd("Herdr")
    eq(child.lua_get("_G.msgs[1]"):find("no_such_action", 1, true) ~= nil, true)
end

T["tree starts disconnected"] = function()
    child.lua([[require("herdr").setup({})]])
    child.cmd("Herdr")
    eq(child.lua_get([[require("herdr.connection").active]]), vim.NIL)
    eq(tree_text():find("press C to connect", 1, true) ~= nil, true)
end

local function open_tall_tree(opts)
    child.lua(
        [[
        require("herdr").setup(...)
        local s = { workspaces = { { workspace_id = "w1", label = "scroll-test" } }, tabs = {}, panes = {} }
        for i = 1, 100 do
            s.tabs[i] = { workspace_id = "w1", tab_id = "t" .. i, label = "terminal " .. i }
            s.panes[i] = { workspace_id = "w1", tab_id = "t" .. i, pane_id = "p" .. i }
        end
        require("herdr.state").snapshot = s
    ]],
        { opts or {} }
    )
    child.cmd("Herdr")
end

T["tree scrolling does not inherit a centered scroll margin"] = function()
    child.lua([[vim.o.scrolloff = 999; _G.code_win = vim.api.nvim_get_current_win()]])
    open_tall_tree()
    local height = child.fn.winheight(0)
    local target = math.floor(height * 3 / 4)
    child.type_keys("gg", (target - 1) .. "j")
    child.cmd("redraw")
    eq({ child.fn.line("w0"), child.fn.winline() }, { 1, target })
    eq(child.wo.scrolloff, 4)
    eq(child.lua_get([[{ vim.go.scrolloff, vim.wo[_G.code_win].scrolloff }]]), { 999, 999 })

    -- Live refreshes leave the cursor and viewport alone.
    child.lua([[require("herdr.tree").render()]])
    child.cmd("redraw")
    eq({ child.fn.line("w0"), child.fn.winline() }, { 1, target })

    -- Native movement starts scrolling at the four-line margin, not halfway.
    child.type_keys("20j")
    child.cmd("redraw")
    local top = target + 20 - (height - 4) + 1
    eq({ child.fn.line("w0"), child.fn.winline() }, { top, height - 4 })
    child.lua([[require("herdr.tree").render()]])
    child.cmd("redraw")
    eq({ child.fn.line("w0"), child.fn.winline() }, { top, height - 4 })

    child.type_keys("q")
    eq(child.wo.scrolloff, 999)
    child.cmd("Herdr")
    eq(child.wo.scrolloff, 4)
end

T["tree scroll margin can be disabled"] = function()
    child.o.scrolloff = 999
    open_tall_tree({ tree = { scrolloff = 0 } })
    eq(child.wo.scrolloff, 0)
    local height = child.fn.winheight(0)
    child.type_keys("gg", (height - 1) .. "j")
    child.cmd("redraw")
    eq({ child.fn.line("w0"), child.fn.winline() }, { 1, height })
    child.type_keys("j")
    child.cmd("redraw")
    eq({ child.fn.line("w0"), child.fn.winline() }, { 2, height })
end

T["tree half-page scrolling ignores global recentering mappings"] = function()
    child.lua([[
        vim.keymap.set("n", "<C-d>", "<C-d>zz")
        vim.keymap.set("n", "<C-u>", "<C-u>zz")
    ]])
    open_tall_tree()
    local target = math.floor(child.fn.winheight(0) * 3 / 4)
    child.type_keys("gg", (target - 1) .. "j")

    -- Compare real keypresses, including counts, with Neovim's native motions.
    for _, motion in ipairs({ { "<C-d>", "\4" }, { "<C-u>", "\21" }, { "5<C-d>", "5\4" }, { "7<C-u>", "7\21" } }) do
        local expected = child.lua(
            [[
            local view, scroll = vim.fn.winsaveview(), vim.wo.scroll
            vim.cmd("normal! " .. ...)
            vim.cmd("redraw")
            local result = { vim.fn.line("."), vim.fn.line("w0"), vim.fn.winline(), vim.wo.scroll }
            vim.fn.winrestview(view)
            vim.wo.scroll = scroll
            return result
        ]],
            { motion[2] }
        )
        child.type_keys(motion[1])
        child.cmd("redraw")
        eq(child.lua_get([[{ vim.fn.line("."), vim.fn.line("w0"), vim.fn.winline(), vim.wo.scroll }]]), expected)
    end

    child.type_keys("q")
    -- Only the tree overrides the user's mappings.
    eq(child.fn.maparg("<C-d>", "n"):lower(), "<c-d>zz")
    eq(child.fn.maparg("<C-u>", "n"):lower(), "<c-u>zz")
    child.cmd("Herdr")
    eq(child.fn.maparg("<C-d>", "n"):lower(), "<c-d>")
    eq(child.fn.maparg("<C-u>", "n"):lower(), "<c-u>")
end

T["tree native scrolling keys can be remapped or disabled"] = function()
    child.lua([[
        vim.keymap.set("n", "<C-d>", "<C-d>zz")
        vim.keymap.set("n", "<C-u>", "<C-u>zz")
    ]])
    open_tall_tree({
        tree = {
            keys = {
                ["<C-d>"] = false,
                ["<C-u>"] = false,
                ["<PageDown>"] = "scroll_down",
                ["<PageUp>"] = "scroll_up",
            },
        },
    })
    eq(child.fn.maparg("<C-d>", "n"):lower(), "<c-d>zz")
    eq(child.fn.maparg("<C-u>", "n"):lower(), "<c-u>zz")
    eq(child.fn.maparg("<PageDown>", "n"):lower(), "<c-d>")
    eq(child.fn.maparg("<PageUp>", "n"):lower(), "<c-u>")
    child.type_keys("?")
    local help = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    eq(help:find("<PageDown>%s+scroll down half a page") ~= nil, true)
    eq(help:find("<PageUp>%s+scroll up half a page") ~= nil, true)
    eq(help:find("<C-d>", 1, true), nil)
    eq(help:find("<C-u>", 1, true), nil)
end

T["tree selection highlights only the focused window"] = function()
    child.lua([[require("herdr").setup({})]])
    child.cmd("Herdr")
    child.lua([[_G.tree_win = vim.api.nvim_get_current_win()]])
    local function selection_visible()
        child.cmd("redraw")
        return child.lua([[
            local info = vim.fn.getwininfo(_G.tree_win)[1]
            local row, col = info.winrow, info.wincol + info.width - 2
            return vim.fn.screenattr(row, col) ~= vim.fn.screenattr(row + 1, col)
        ]])
    end
    eq(child.wo.cursorline, true)
    eq(child.wo.winhighlight:find("CursorLine:HerdrTreeCursorLine", 1, true) ~= nil, true)
    eq(selection_visible(), true)
    child.cmd("wincmd p")
    eq(child.lua_get([[vim.wo[_G.tree_win].cursorline]]), false)
    eq(selection_visible(), false)
    child.cmd("wincmd p")
    eq(child.wo.cursorline, true)
    child.lua([[vim.api.nvim_exec_autocmds("FocusLost", {})]])
    eq(child.wo.cursorline, false)
    child.lua([[vim.api.nvim_exec_autocmds("FocusGained", {})]])
    eq(child.wo.cursorline, true)
end

T["connecting without herdr shows a clear error"] = function()
    child.lua([[require("herdr").setup({ herdr_bin = "herdr-nvim-test-missing" })]])
    child.cmd("Herdr")
    child.lua([[require("herdr.connection").switch({ session = "main" })]])
    H.wait_child(child, [[(require("herdr.state").error or ""):find("not found", 1, true) ~= nil]])
    vim.wait(200)
    eq(tree_text():find("not found", 1, true) ~= nil, true)
end

T["a trusted .nvim.lua (exrc) connects via vim.g.herdr_connection"] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = assert(vim.uv.fs_realpath(dir)) -- trust entries use real paths (/var -> /private/var on macOS)
    local file = dir .. "/.nvim.lua"
    vim.fn.writefile({ 'vim.g.herdr_connection = "herdr-nvim-test-host:agents"' }, file)
    -- Trust it the way :trust does (by buffer: path-based "allow" is 0.12+ only).
    vim.fn.mkdir(vim.fn.stdpath("state"), "p")
    local buf = vim.fn.bufadd(file)
    vim.cmd("noautocmd call bufload(" .. buf .. ")") -- no filetype plugins in the runner
    vim.secure.trust({ action = "allow", bufnr = buf })
    vim.api.nvim_buf_delete(buf, { force = true })

    -- 'exrc' is skipped with `-u`/`--clean` (mini.test children always use
    -- --clean), so run a standalone Neovim like a normal user: a user config
    -- (in the isolated XDG_CONFIG_HOME) that loads the test init.
    local user_config = vim.env.XDG_CONFIG_HOME .. "/nvim/init.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(user_config, ":h"), "p")
    vim.fn.writefile({
        ("dofile(%q)"):format(H.root .. "/tests/init.lua"),
        'require("herdr").setup({ herdr_bin = "herdr-nvim-test-missing" })',
    }, user_config)
    -- herdr-nvim connects on VimEnter, after the project config ran; report after it.
    local probe = [[autocmd VimEnter * ++once lua
        local c = require("herdr.connection")
        vim.wait(3000, function() return c.active ~= nil end, 20)
        io.write("var=" .. tostring(vim.g.herdr_connection) .. " active=" .. c.label(c.active))
        c.disconnect()
        vim.cmd("qa!")
    ]]
    local res = vim.system({
        vim.v.progpath,
        "--headless",
        "--cmd",
        "set exrc | cd " .. dir,
        "-c",
        (probe:gsub("\n%s*", " ")),
    }, { text = true }):wait(15000)
    vim.fn.delete(user_config)
    eq(res.stdout, "var=herdr-nvim-test-host:agents active=herdr-nvim-test-host:agents")
    vim.fn.delete(dir, "rf")
end

T["no vim.g.herdr_connection: nothing connects"] = function()
    child.lua([[require("herdr").setup({})]])
    vim.wait(200)
    eq(child.lua_get([[require("herdr.connection").active]]), vim.NIL)
end

T["vim.g.herdr_connection with an injected ssh option is rejected"] = function()
    child.lua([[
        vim.g.herdr_connection = { remote = "-oProxyCommand=touch /tmp/pwned", session = "main" }
        _G.msgs = {}
        vim.notify = function(m) table.insert(_G.msgs, m) end
        require("herdr").setup({})
    ]])
    H.wait_child(child, "#_G.msgs > 0")
    eq(child.lua_get([[require("herdr.connection").active]]), vim.NIL)
    eq(child.lua_get("_G.msgs[1]"):find("invalid SSH target", 1, true) ~= nil, true)
end

T["checkhealth runs"] = function()
    child.lua([[require("herdr").setup({})]])
    child.cmd("checkhealth herdr")
    local text = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    eq(text:find("herdr-nvim: Neovim", 1, true) ~= nil, true)
    eq(text:find("not connected", 1, true) ~= nil, true)
end

T["style borrows snacks' explorer icons"] = function()
    child.lua([[
        require("snacks").setup({ picker = { icons = { files = { dir = "D ", dir_open = "O " } } } })
        require("herdr").setup({})
    ]])
    local style = child.lua_get([[require("herdr.style").get()]])
    eq({ style.source, style.icons.space_closed, style.icons.space_open }, { "snacks", "D ", "O " })
end

return T
