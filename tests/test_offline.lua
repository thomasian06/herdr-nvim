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
    for _, lhs in ipairs({ "<leader>aa", "<leader>ap", "<leader>ac", "<leader>an" }) do
        eq(child.fn.maparg(lhs, "n") ~= "", true)
    end
end

T["setup: keymaps can be disabled"] = function()
    child.lua([[require("herdr").setup({ keymaps = false })]])
    eq(child.fn.maparg("<leader>aa", "n"), "")
end

T["tree starts disconnected"] = function()
    child.lua([[require("herdr").setup({})]])
    child.cmd("Herdr")
    eq(child.lua_get([[require("herdr.connection").active]]), vim.NIL)
    eq(tree_text():find("press C to connect", 1, true) ~= nil, true)
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
