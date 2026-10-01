-- Pure logic: no child Neovim, no Herdr.
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["connection"] = MiniTest.new_set()

T["connection"]["parse"] = function()
    local c = require("herdr.connection")
    local function pick(x)
        return { remote = x.remote, session = x.session }
    end
    eq(pick(c.parse("devbox")), { remote = "devbox", session = "main" })
    eq(pick(c.parse("devbox:agents")), { remote = "devbox", session = "agents" })
    eq(pick(c.parse("me@devbox")), { remote = "me@devbox", session = "main" })
    eq(pick(c.parse("local")), { remote = nil, session = "main" })
    eq(pick(c.parse("local:x")), { remote = nil, session = "x" })
end

T["connection"]["validate rejects ssh option injection"] = function()
    local c = require("herdr.connection")
    eq(c.validate({ remote = "-oProxyCommand=touch /tmp/x", session = "main" }) ~= nil, true)
    eq(c.validate({ remote = "a b", session = "main" }) ~= nil, true)
    eq(c.validate({ remote = "devbox", session = "-x" }) ~= nil, true)
    eq(c.validate({ remote = "me@devbox", session = "main" }), nil)
    eq(c.validate({ session = "main", projects_dir = "~/projects" }), nil)
end

T["connect() without a target opens the picker"] = function()
    local connection = require("herdr.connection")
    local orig_pick, orig_resolve = connection.pick, connection.resolve
    local picked, resolved = 0, {}
    connection.pick = function()
        picked = picked + 1
    end
    connection.resolve = function(target)
        resolved[#resolved + 1] = target
    end
    local ok, err = pcall(function()
        require("herdr").connect()
        require("herdr").connect("")
        require("herdr").connect("devbox:main")
    end)
    connection.pick, connection.resolve = orig_pick, orig_resolve
    assert(ok, err)
    eq({ picked, resolved }, { 2, { "devbox:main" } })
end

T["terminal.parse_name"] = function()
    local t = require("herdr.terminal")
    local c, pane = t.parse_name("herdr://devbox:main/w1:p2/fix-login")
    eq({ c.remote, c.session, pane }, { "devbox", "main", "w1:p2" })
    c, pane = t.parse_name("herdr://local:agents/w3:p1")
    eq({ c.remote, c.session, pane }, { nil, "agents", "w3:p1" })
    eq(t.parse_name("herdr://nonsense"), nil)
end

T["every tree icon is a visible glyph"] = function()
    local icons = require("herdr.style").get().icons
    for name, icon in pairs(icons) do
        MiniTest.expect.no_equality(vim.trim(icon), "", name)
    end
    -- Plain terminals and agents must be told apart at a glance.
    MiniTest.expect.no_equality(icons.shell, icons.agent)
end

T["status"] = MiniTest.new_set()

T["status"]["aggregate follows Herdr's priority"] = function()
    local s = require("herdr.state")
    eq(s.aggregate({ "idle", "working", "done" }), "done")
    eq(s.aggregate({ "idle", "working" }), "working")
    eq(s.aggregate({ "done", "blocked" }), "blocked")
    eq(s.aggregate({}), "unknown")
end

T["status"]["done becomes idle once seen, until it works again"] = function()
    local s = require("herdr.state")
    s.snapshot = { panes = { { pane_id = "w1:p1", agent_status = "done" } } }
    eq(s.pane_status(s.snapshot.panes[1]), "done")
    s.mark_seen("w1:p1")
    eq(s.pane_status(s.snapshot.panes[1]), "idle")
    s.snapshot = nil
    s.seen = {}
end

T["status"]["dots glyphs like Herdr"] = function()
    local s = require("herdr.state")
    eq({ s.status_icon("working"), s.status_icon("blocked"), s.status_icon("done"), s.status_icon("idle") }, {
        "●",
        "●",
        "●",
        "○",
    })
    eq(s.status("done").hl, "HerdrDone")
    eq(s.status("bogus").hl, "HerdrUnknown")
end

--- Point Herdr's config at a temporary file with `lines` for the test.
local function with_herdr_config(lines, fn)
    local file = vim.fn.tempname() .. ".toml"
    vim.fn.writefile(lines, file)
    local old = vim.env.HERDR_CONFIG_PATH
    vim.env.HERDR_CONFIG_PATH = file
    local ok, err = pcall(fn)
    vim.env.HERDR_CONFIG_PATH = old
    os.remove(file)
    if not ok then
        error(err, 0)
    end
end

T["notify follows Herdr's transitions"] = function()
    with_herdr_config({ "[ui.toast]", "delay_seconds = 0" }, function()
        local notify = require("herdr.notify")
        local fired = {}
        local real_play, real_notify = notify.play, vim.notify
        notify.play = function(kind)
            fired[#fired + 1] = kind
        end
        vim.notify = function() end
        local function snap(status)
            return {
                panes = {
                    { pane_id = "w:p1", tab_id = "w:t1", workspace_id = "w", agent = "pi", agent_status = status },
                },
            }
        end
        notify._on_snapshot(nil)
        for _, st in ipairs({ "working", "idle", "blocked", "idle", "idle", "unknown", "idle" }) do
            notify._on_snapshot(snap(st))
        end
        eq(fired, { "done", "request", "done", "done" })
        fired = {}
        notify._on_snapshot(nil)
        notify._on_snapshot(snap("idle")) -- the first snapshot after connecting only primes
        eq(fired, {})
        notify.play, vim.notify = real_play, real_notify
    end)
end

T["notify waits Herdr's delay and re-checks"] = function()
    with_herdr_config({ "[ui.toast]", "delay_seconds = 0.2" }, function()
        local notify, state = require("herdr.notify"), require("herdr.state")
        local fired = {}
        local real_play, real_notify = notify.play, vim.notify
        notify.play = function(kind)
            fired[#fired + 1] = kind
        end
        vim.notify = function() end
        local function snap(status)
            state.snapshot = {
                panes = {
                    { pane_id = "w:p9", tab_id = "w:t9", workspace_id = "w", agent = "pi", agent_status = status },
                },
            }
            notify._on_snapshot(state.snapshot)
        end
        notify._on_snapshot(nil)
        snap("working")
        snap("idle") -- finished...
        snap("working") -- ...but back to work within the delay: stays quiet
        vim.wait(400)
        eq(fired, {})
        snap("idle") -- finished for real
        vim.wait(400)
        eq(fired, { "done" })
        state.snapshot = nil
        notify.play, vim.notify = real_play, real_notify
    end)
end

T["per-agent sounds follow [ui.sound.agents]"] = function()
    with_herdr_config({ "[ui.sound.agents]", 'claude = "off"', 'open_code = "off"', 'droid = "on"' }, function()
        local notify = require("herdr.notify")
        eq(notify.agent_sound_on("pi"), true)
        eq(notify.agent_sound_on("claude"), false)
        eq(notify.agent_sound_on("opencode"), false)
        eq(notify.agent_sound_on("droid"), true)
    end)
    with_herdr_config({}, function()
        eq(require("herdr.notify").agent_sound_on("droid"), false) -- off by default
    end)
end

T["simultaneous finishes play one sound"] = function()
    local notify = require("herdr.notify")
    local plays = 0
    local real_system, real_player = vim.system, notify.player_cmd
    -- Independent of which audio player the machine has (CI Linux has none).
    notify.player_cmd = function()
        return { "true" }
    end
    vim.system = function()
        plays = plays + 1
        return { wait = function() end }
    end
    with_herdr_config({}, function()
        local old = vim.env.HERDR_DISABLE_SOUND
        vim.env.HERDR_DISABLE_SOUND = nil
        for _ = 1, 5 do
            notify.play("request")
        end
        vim.env.HERDR_DISABLE_SOUND = old
    end)
    vim.system, notify.player_cmd = real_system, real_player
    eq(plays, 1)
end

T["status parsing"] = function()
    local t = require("herdr.transport")
    local st = t.parse_status('{"status":"running","running":true,"socket":"/x/herdr.sock","compatible":true}')
    eq({ st.running, st.socket, st.compatible }, { true, "/x/herdr.sock", true })
    eq(t.parse_status('{"status":"not_running","running":false,"compatible":null}').running, false)
    eq(t.parse_status("not json").running, false)
end

T["our ssh master only adds options the user's config leaves unset"] = function()
    local t = require("herdr.transport")
    local function has(list, kv)
        return vim.tbl_contains(list, kv)
    end
    local defaults = t.master_options({ serveraliveinterval = "0", connecttimeout = "none" })
    eq(
        { has(defaults, "ConnectTimeout=15"), has(defaults, "ServerAliveInterval=15"), has(defaults, "BatchMode=yes") },
        {
            true,
            true,
            true,
        }
    )
    local user = t.master_options({ serveraliveinterval = "30", connecttimeout = "60" })
    eq({ has(user, "ConnectTimeout=15"), has(user, "ServerAliveInterval=15") }, { false, false })
    -- Host key policy is never overridden (e.g. ephemeral hosts with StrictHostKeyChecking no).
    eq(
        vim.iter(defaults):any(function(x)
            return x:find("StrictHostKeyChecking", 1, true) ~= nil
        end),
        false
    )
end

T["remote herdr discovery skips mise shims and finds remote_path"] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/mise/shims", "p")
    vim.fn.mkdir(dir .. "/bin", "p")
    local fake = { "#!/bin/sh", '[ "$1 $2" = "status client" ] && echo "{}"' }
    vim.fn.writefile(fake, dir .. "/mise/shims/herdr")
    vim.fn.writefile(fake, dir .. "/bin/herdr")
    vim.uv.fs_chmod(dir .. "/mise/shims/herdr", 493)
    vim.uv.fs_chmod(dir .. "/bin/herdr", 493)
    local config = require("herdr.config")
    local saved = config.options.remote_path
    config.options.remote_path = { dir .. "/bin" }
    local script = require("herdr.transport").find_herdr_script()
    config.options.remote_path = saved
    local res = vim.system(
        { "sh", "-c", script },
        { text = true, env = { PATH = dir .. "/mise/shims:/usr/bin:/bin", HOME = dir } }
    ):wait()
    eq(vim.trim(res.stdout), dir .. "/bin/herdr")
    vim.fn.delete(dir, "rf")
end

T["HERDR_CONFIG_PATH takes precedence"] = function()
    with_herdr_config({ "[ui]", 'status_indicators = "symbols"' }, function()
        eq(require("herdr.herdr_config").section("ui").status_indicators, "symbols")
    end)
end

T["history merge"] = function()
    local history = require("herdr.history")
    local function text(from, to, screen)
        local t = {}
        for i = from, to do
            t[#t + 1] = "\27[32mline " .. i .. "\27[0m"
        end
        vim.list_extend(t, screen or {})
        return table.concat(t, "\r\n")
    end
    local c = history._cache_for("unit:p1")
    eq(history._merge(c, text(1, 100), 10, true), true)
    eq({ #c.stable, #c.screen }, { 90, 10 })
    eq(history._merge(c, text(50, 130), 10, false), true) -- overlap: only new lines settle
    eq(#c.stable, 120)
    eq({ c.plain[1], c.plain[120] }, { "line 1", "line 120" })
    eq(history._merge(c, text(50, 120, { "status 1", "status 2" }), 2, false), true) -- screen-only change
    eq(#c.stable, 120)
    eq(history._merge(c, text(500, 520), 5, false), false) -- no overlap: ask for a full read
    eq(history._merge(c, text(500, 520), 5, true), true) -- full read, still no overlap: mark the gap
    eq(c.plain[121]:find("not loaded", 1, true) ~= nil, true)
    eq(c.plain[122], "line 500")
    history._caches["unit:p1"] = nil
end

T["herdr_config reads Herdr's settings"] = function()
    local dir = vim.env.XDG_CONFIG_HOME .. "/herdr"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
        "[ui]",
        'status_indicators = "symbols" # comment',
        "[ui.sound]",
        "enabled = false",
        'done_path = "sounds/done.mp3"',
    }, dir .. "/config.toml")
    local cfg = require("herdr.herdr_config")
    eq(cfg.section("ui").status_indicators, "symbols")
    local sound = cfg.section("ui.sound", true)
    eq(sound.enabled, false)
    eq(sound.done_path, dir .. "/sounds/done.mp3")
    vim.fn.delete(dir, "rf")
end

return T
