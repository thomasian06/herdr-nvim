-- Agent notifications, following Herdr's own rules:
--   - an agent becomes blocked (needs input)       -> "request" sound + notification
--   - an agent finishes (working/blocked -> idle)  -> "done" sound + notification,
--     unless you are looking at it (its terminal is the current window and
--     Neovim has focus), like Herdr skips the active tab.
-- Like Herdr, a notification waits [ui.toast] delay_seconds (default 1) and is
-- re-checked before firing (so an agent that flickers back to work stays
-- quiet); a newer event for the same pane replaces a pending one.
--
-- Sounds are Herdr's own (bundled). Herdr's settings are honored:
-- [ui.sound] enabled/path/done_path/request_path, [ui.sound.agents]
-- (default/on/off per agent; droid is off by default), HERDR_DISABLE_SOUND,
-- and HERDR_CONFIG_PATH.

local config = require("herdr.config")
local state = require("herdr.state")

local M = {}

local previous = {} ---@type table<string, string> pane_id -> last agent_status
local previous_agent = {} ---@type table<string, string|false> pane_id -> last agent label
local primed = false -- the first snapshot after connecting only records statuses
local focused = true -- whether Neovim has focus (FocusGained/FocusLost)

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

-- Herdr config -------------------------------------------------------------------

local function herdr_sound_config()
    return require("herdr.herdr_config").section("ui.sound", true)
end

local function sound_file(kind)
    local herdr = herdr_sound_config()
    local specific = kind == "done" and herdr.done_path or herdr.request_path
    local chosen = specific or herdr.path
    if type(chosen) == "string" then
        chosen = vim.fn.expand(chosen)
        if vim.uv.fs_stat(chosen) then
            return chosen
        end
    end
    return plugin_root .. "/assets/sounds/" .. kind .. ".mp3"
end

local function sound_enabled()
    local o = config.options.notify
    if o.sound == false or (vim.env.HERDR_DISABLE_SOUND and vim.env.HERDR_DISABLE_SOUND ~= "") then
        return false
    end
    if o.sound == "herdr" and herdr_sound_config().enabled == false then
        return false
    end
    return true
end

local PLAYERS = {
    { "paplay" },
    { "pw-play" },
    { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet" },
    { "mpg123", "-q" },
    { "mpv", "--no-video", "--really-quiet" },
}

-- Herdr's per-agent sound switches ([ui.sound.agents]); droid defaults off.
local AGENT_DEFAULT_OFF = { droid = true }

--- Whether sounds are on for an agent label ("pi", "claude", "opencode", ...).
function M.agent_sound_on(agent)
    if not agent or agent == "" then
        return true
    end
    local overrides = require("herdr.herdr_config").section("ui.sound.agents")
    local key = agent:lower()
    local value = overrides[key] or overrides[key:gsub("[^%w]", "_")]
    if key == "opencode" and value == nil then
        value = overrides.open_code
    end
    if value == "off" or value == false then
        return false
    elseif value == "on" or value == true then
        return true
    end
    return not AGENT_DEFAULT_OFF[key]
end

local last_played = {} ---@type table<string, integer> kind -> uv.now()
local BURST_MS = 400

--- Play a notification sound ("done" | "request") in the background. Several
--- agents finishing at once play one sound, not a burst.
function M.play(kind)
    if not sound_enabled() then
        return
    end
    local now = vim.uv.now()
    if last_played[kind] and now - last_played[kind] < BURST_MS then
        return
    end
    last_played[kind] = now
    local file = sound_file(kind)
    local cmd
    if vim.fn.has("mac") == 1 then
        cmd = { "afplay", file }
    else
        for _, p in ipairs(PLAYERS) do
            if vim.fn.executable(p[1]) == 1 then
                cmd = vim.list_extend(vim.deepcopy(p), { file })
                break
            end
        end
    end
    if cmd then
        pcall(vim.system, cmd, { detach = true })
    end
end

-- Transitions ----------------------------------------------------------------------

local function is_watched(pane_id)
    if not focused then
        return false
    end
    local buf = vim.api.nvim_get_current_buf()
    return vim.b[buf].herdr_pane_id == pane_id
end

local function describe(p)
    local name = state.pane_label(p)
    local tab = state.tab(p.tab_id)
    if tab and tab.label and not tab.label:match("^%d+$") and #state.tab_panes(tab.tab_id) == 1 then
        name = tab.label
    end
    local agent = p.display_agent or p.agent
    local ws = state.workspace(p.workspace_id)
    return name .. (agent and (" (" .. agent .. ")") or ""), ws and ws.label
end

local function announce(kind, p)
    local o = config.options.notify
    if not o.enabled or not o.on[kind == "request" and "blocked" or "done"] then
        return
    end
    if M.agent_sound_on(p.agent) then
        M.play(kind)
    end
    if o.message then
        local what, space = describe(p)
        local msg = kind == "request" and (what .. " needs input") or (what .. " is done")
        vim.notify(
            msg .. (space and ("  [" .. space .. "]") or ""),
            kind == "request" and vim.log.levels.WARN or vim.log.levels.INFO,
            { title = "herdr" }
        )
    end
end

local pending = {} ---@type table<string, uv.uv_timer_t> pane_id -> timer

--- Herdr's notification delay ([ui.toast] delay_seconds, 0..3600, default 1).
function M.delay_ms()
    local secs = tonumber(require("herdr.herdr_config").section("ui.toast").delay_seconds) or 1
    return math.floor(math.max(0, math.min(secs, 3600)) * 1000)
end

--- Still true when it is time to notify? (re-checked after the delay)
local function still_applies(kind, pane_id)
    local p = state.pane(pane_id)
    if not p then
        return false
    end
    if kind == "request" then
        return p.agent_status == "blocked"
    end
    return (p.agent_status == "done" or p.agent_status == "idle") and not is_watched(pane_id)
end

local function schedule(kind, p)
    local id = p.pane_id
    if pending[id] then
        pending[id]:stop()
        pending[id]:close()
        pending[id] = nil
    end
    local delay = M.delay_ms()
    if delay == 0 then
        return announce(kind, p)
    end
    local timer = assert(vim.uv.new_timer())
    pending[id] = timer
    timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            if pending[id] == timer then
                pending[id] = nil
                timer:close()
            end
            if still_applies(kind, id) then
                announce(kind, state.pane(id) or p)
            end
        end)
    )
end

local function on_snapshot(snapshot)
    if not snapshot then
        previous, previous_agent, primed = {}, {}, false
        return
    end
    local seen = {}
    for _, p in ipairs(snapshot.panes or {}) do
        seen[p.pane_id] = true
        local prev, now = previous[p.pane_id], p.agent_status
        local prev_label, label = previous_agent[p.pane_id], p.agent or false
        if primed and prev and prev ~= now then
            if now == "blocked" then
                schedule("request", p)
            elseif
                (now == "idle" or now == "done")
                and (
                    prev == "working"
                    or prev == "blocked"
                    -- Herdr also counts unknown -> idle for the same agent as a completion.
                    or (prev == "unknown" and prev_label and prev_label == label)
                )
                and not is_watched(p.pane_id)
            then
                schedule("done", p)
            end
        end
        previous[p.pane_id] = now
        previous_agent[p.pane_id] = label
    end
    for id in pairs(previous) do
        if not seen[id] then
            previous[id], previous_agent[id] = nil, nil
        end
    end
    primed = true
end

function M.setup()
    state.on_change(function(snapshot)
        vim.schedule(function()
            on_snapshot(snapshot)
        end)
    end)
    local group = vim.api.nvim_create_augroup("herdr_notify", { clear = true })
    vim.api.nvim_create_autocmd("FocusGained", {
        group = group,
        callback = function()
            focused = true
        end,
    })
    vim.api.nvim_create_autocmd("FocusLost", {
        group = group,
        callback = function()
            focused = false
        end,
    })
end

-- for tests
M._on_snapshot = on_snapshot
M._sound_file = sound_file

return M
