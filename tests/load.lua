-- Offline check: every module loads, setup() works, keymaps and the command
-- exist, and the tree renders without a server.
-- Usage: nvim --headless -u NONE -l tests/load.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.g.mapleader = " "
vim.cmd("runtime plugin/herdr.lua")

local failures = 0
local function check(name, ok, detail)
    io.stdout:write((ok and "ok   " or "FAIL ") .. name .. (detail and ("  " .. detail) or "") .. "\n")
    if not ok then
        failures = failures + 1
    end
end

for _, mod in ipairs({
    "herdr",
    "herdr.config",
    "herdr.api",
    "herdr.transport",
    "herdr.state",
    "herdr.style",
    "herdr.terminal",
    "herdr.tree",
    "herdr.picker",
    "herdr.connection",
    "herdr.health",
    "herdr.notify",
    "herdr.ui",
}) do
    local ok, err = pcall(require, mod)
    check("require " .. mod, ok, not ok and tostring(err) or nil)
end

local connection = require("herdr.connection")
local function same(a, b)
    return a.remote == b.remote and a.session == b.session
end
check("parse host", same(connection.parse("devbox"), { remote = "devbox", session = "main" }))
check("parse host:session", same(connection.parse("devbox:agents"), { remote = "devbox", session = "agents" }))
check("parse user@host", same(connection.parse("me@devbox"), { remote = "me@devbox", session = "main" }))
check("parse local", same(connection.parse("local"), { remote = nil, session = "main" }))

require("herdr").setup({ herdr_bin = "herdr-nvim-test-missing-binary" })
check("command :Herdr", vim.fn.exists(":Herdr") == 2)
check("keymap <leader>aa", vim.fn.maparg("<leader>aa", "n") ~= "")
check("keymap <leader>ap", vim.fn.maparg("<leader>ap", "n") ~= "")
check("keymap <leader>an", vim.fn.maparg("<leader>an", "n") ~= "")

require("herdr").setup({ keymaps = false })
vim.keymap.del("n", "<leader>aa")
vim.keymap.del("n", "<leader>ap")
require("herdr").setup({ keymaps = false })
check("keymaps = false", vim.fn.maparg("<leader>aa", "n") == "")

-- The tree opens disconnected: nothing connects on its own.
require("herdr.config").setup({ herdr_bin = "herdr-nvim-test-missing-binary" })
local ok, err = pcall(vim.cmd, "Herdr toggle")
check("open tree", ok, not ok and tostring(err) or nil)
local function tree_text()
    return table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("herdr://tree"), 0, -1, false), "\n")
end
vim.wait(300)
check("tree starts disconnected", tree_text():find("press C to connect", 1, true) ~= nil, tree_text())
check("no connection active", connection.active == nil)

-- Connecting (local, herdr missing) shows a clear error.
connection.switch({ remote = nil, session = "main" })
vim.wait(3000, function()
    return require("herdr.state").error ~= nil or require("herdr.transport").error ~= nil
end, 50)
vim.wait(200)
check("tree shows missing-herdr error", tree_text():find("not found", 1, true) ~= nil, tree_text())
connection.disconnect()
check("disconnect", connection.active == nil)

-- SSH option injection is rejected.
check("reject -o target", connection.validate({ remote = "-oProxyCommand=touch /tmp/x", session = "main" }) ~= nil)
check("reject spaced target", connection.validate({ remote = "a b", session = "main" }) ~= nil)
check("accept user@host", connection.validate({ remote = "me@devbox", session = "main" }) == nil)

-- Project file: untrusted does nothing; trusted connects.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/sub", "p")
local file = dir .. "/" .. connection.PROJECT_FILE
vim.fn.writefile({ '{"remote": "herdr-nvim-test-host", "session": "agents"}' }, file)
local real_select = vim.ui.select
local answer, asked
vim.ui.select = function(items, opts, cb)
    asked = opts.prompt
    cb(answer)
end
check("untrusted file: status unknown", connection.trust_status(file) == "unknown")
answer = "Not now"
connection.autoconnect(dir .. "/sub")
vim.wait(500, function()
    return asked ~= nil
end, 20)
check("untrusted file: asks before connecting", asked and asked:find("herdr-nvim-test-host", 1, true) ~= nil, asked)
check("'Not now': no connection", connection.active == nil)
answer, asked = "Trust and connect", nil
local real_switch = connection.switch
local switched
connection.switch = function(c)
    switched = c
end
connection.autoconnect(dir .. "/sub")
vim.wait(500, function()
    return switched ~= nil
end, 20)
check(
    "'Trust and connect': connects",
    switched and switched.remote == "herdr-nvim-test-host" and switched.session == "agents"
)
check("trusted file: status allowed", connection.trust_status(file) == "allowed")
vim.fn.writefile({ '{"remote": "other-host"}' }, file)
check("edited file: trust resets", connection.trust_status(file) == "unknown")
connection.switch = real_switch
vim.ui.select = real_select
vim.fn.writefile({ '{"remote": "-oProxyCommand=touch /tmp/pwned"}' }, file)
vim.secure.trust({ action = "allow", path = file })
local bad, why = connection.read_project(file)
check("project file with injected target rejected", bad == nil and why ~= nil, tostring(why))
vim.secure.trust({ action = "remove", path = file })
vim.fn.delete(dir, "rf")

-- Notifications follow Herdr's transition rules.
do
    local notify = require("herdr.notify")
    local fired = {}
    local real_play, real_notify = notify.play, vim.notify
    notify.play = function(kind)
        fired[#fired + 1] = kind
    end
    vim.notify = function() end
    local function snap(status, agent)
        return {
            panes = {
                { pane_id = "w:p1", tab_id = "w:t1", workspace_id = "w", agent = agent or "pi", agent_status = status },
            },
        }
    end
    notify._on_snapshot(nil)
    notify._on_snapshot(snap("working")) -- first snapshot only primes
    notify._on_snapshot(snap("idle")) -- working -> idle: done
    notify._on_snapshot(snap("blocked")) -- -> blocked: request
    notify._on_snapshot(snap("idle")) -- blocked -> idle: done
    notify._on_snapshot(snap("idle")) -- no change
    notify._on_snapshot(snap("unknown"))
    notify._on_snapshot(snap("idle")) -- unknown -> idle, same agent: done
    check("notify transitions", table.concat(fired, ",") == "done,request,done,done", table.concat(fired, ","))
    fired = {}
    notify._on_snapshot(nil)
    notify._on_snapshot(snap("idle")) -- after reconnect: primes, no sound
    check("no notification on connect", #fired == 0)
    check("bundled sound exists", vim.uv.fs_stat(notify._sound_file("done")) ~= nil, notify._sound_file("done"))
    notify.play, vim.notify = real_play, real_notify
end

os.exit(failures == 0 and 0 or 1)
