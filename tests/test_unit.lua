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

T["terminal.parse_name"] = function()
    local t = require("herdr.terminal")
    local c, pane = t.parse_name("herdr://devbox:main/w1:p2/fix-login")
    eq({ c.remote, c.session, pane }, { "devbox", "main", "w1:p2" })
    c, pane = t.parse_name("herdr://local:agents/w3:p1")
    eq({ c.remote, c.session, pane }, { nil, "agents", "w3:p1" })
    eq(t.parse_name("herdr://nonsense"), nil)
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

T["notify follows Herdr's transitions"] = function()
    local notify = require("herdr.notify")
    local fired = {}
    local real_play, real_notify = notify.play, vim.notify
    notify.play = function(kind)
        fired[#fired + 1] = kind
    end
    vim.notify = function() end
    local function snap(status)
        return {
            panes = { { pane_id = "w:p1", tab_id = "w:t1", workspace_id = "w", agent = "pi", agent_status = status } },
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
