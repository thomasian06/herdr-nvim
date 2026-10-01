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

T["project file asks before connecting"] = function()
    local dir = child.lua_get("vim.fn.tempname()")
    child.lua(
        [[
        local dir = ...
        vim.fn.mkdir(dir .. "/sub", "p")
        vim.fn.writefile({ '{"remote": "herdr-nvim-test-host", "session": "agents"}' }, dir .. "/.herdr-nvim.json")
        require("herdr").setup({})
        _G.asked, _G.switched = nil, nil
        vim.ui.select = function(_, opts, cb) _G.asked = opts.prompt; cb(_G.answer) end
        require("herdr.connection").switch = function(c) _G.switched = c end
    ]],
        { dir }
    )
    child.lua([[_G.answer = "Not now"; require("herdr.connection").autoconnect(...)]], { dir .. "/sub" })
    H.wait_child(child, "_G.asked ~= nil")
    eq(child.lua_get("_G.asked"):find("herdr-nvim-test-host", 1, true) ~= nil, true)
    eq(child.lua_get("_G.switched"), vim.NIL)

    child.lua([[_G.answer = "Trust and connect"; require("herdr.connection").autoconnect(...)]], { dir .. "/sub" })
    H.wait_child(child, "_G.switched ~= nil")
    eq(child.lua_get("_G.switched.remote"), "herdr-nvim-test-host")
    eq(child.lua_get([[require("herdr.connection").trust_status(...)]], { dir .. "/.herdr-nvim.json" }), "allowed")

    -- Editing the file resets its trust.
    child.lua([[vim.fn.writefile({ '{"remote": "other"}' }, ...)]], { dir .. "/.herdr-nvim.json" })
    eq(child.lua_get([[require("herdr.connection").trust_status(...)]], { dir .. "/.herdr-nvim.json" }), "unknown")
end

T["project file with an injected ssh option is rejected"] = function()
    local path = child.lua_get("vim.fn.tempname()") .. ".json"
    child.lua(
        [[
        local path = ...
        vim.fn.writefile({ '{"remote": "-oProxyCommand=touch /tmp/pwned"}' }, path)
        require("herdr.connection").trust_allow(path)
    ]],
        { path }
    )
    eq(
        child.lua_get([[select(2, require("herdr.connection").read_project(...))]], { path }):find("invalid", 1, true)
            ~= nil,
        true
    )
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
