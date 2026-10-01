-- Agent notifications, following Herdr's own rules:
--   - an agent becomes blocked (needs input)       -> "request" sound + notification
--   - an agent finishes (working/blocked -> idle)  -> "done" sound + notification,
--     unless you are looking at it (its terminal is the current window and
--     Neovim has focus), like Herdr skips the active tab.
--
-- Sounds are Herdr's own (bundled), and Herdr's `[ui.sound]` settings in
-- ~/.config/herdr/config.toml (enabled, path, done_path, request_path) and
-- HERDR_DISABLE_SOUND are honored.

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

--- Play a notification sound ("done" | "request") in the background.
function M.play(kind)
    if not sound_enabled() then
        return
    end
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
    M.play(kind)
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
                announce("request", p)
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
                announce("done", p)
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
