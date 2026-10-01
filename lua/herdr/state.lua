-- Live mirror of the Herdr session.
--
-- Holds the latest `session.snapshot` and keeps it fresh: any subscribed server
-- event schedules a (debounced) re-fetch. Agent status changes are only
-- delivered per pane, so the subscription is rebuilt whenever the pane set
-- changes.

local api = require("herdr.api")
local config = require("herdr.config")

local M = {}

---@type table? latest snapshot (workspaces, tabs, panes, layouts, agents, focused_*_id)
M.snapshot = nil
M.error = nil

local listeners = {}
local refresh_timer
local refreshing, refresh_again = false, false
local sub, sub_key
local retry_timer
local active = false
local epoch = 0 -- bumps on reset; responses from an older epoch are dropped

local GLOBAL_EVENTS = {
    "workspace.created",
    "workspace.updated",
    "workspace.renamed",
    "workspace.moved",
    "workspace.reordered",
    "workspace.closed",
    "workspace.focused",
    "tab.created",
    "tab.closed",
    "tab.focused",
    "tab.renamed",
    "tab.moved",
    "pane.created",
    "pane.closed",
    "pane.updated",
    "pane.focused",
    "pane.moved",
    "pane.exited",
    "pane.agent_detected",
    "layout.updated",
}

local function emit()
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, M.snapshot, M.error)
        if not ok then
            vim.notify("herdr-nvim listener error: " .. tostring(err), vim.log.levels.ERROR)
        end
    end
end

local function pane_key(snapshot)
    local ids = {}
    for _, p in ipairs(snapshot.panes or {}) do
        ids[#ids + 1] = p.pane_id
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

local ensure_subscription

local function schedule_retry()
    if retry_timer or not active then
        return
    end
    retry_timer = vim.defer_fn(function()
        retry_timer = nil
        M.refresh()
    end, 2000)
end

function ensure_subscription(snapshot)
    local key = pane_key(snapshot)
    if sub and key == sub_key then
        return
    end
    if sub then
        local old = sub
        sub = nil
        old.close()
    end
    sub_key = key
    local subs = {}
    for _, t in ipairs(GLOBAL_EVENTS) do
        subs[#subs + 1] = { type = t }
    end
    for _, p in ipairs(snapshot.panes or {}) do
        subs[#subs + 1] = { type = "pane.agent_status_changed", pane_id = p.pane_id }
    end
    local this
    local my_epoch = epoch
    this = api.subscribe(subs, function()
        if my_epoch == epoch then
            M.refresh()
        end
    end, function(err)
        if sub ~= this or my_epoch ~= epoch then
            return -- replaced or closed on purpose
        end
        sub, sub_key = nil, nil
        if err then
            M.error = "event stream: " .. err
            emit()
        end
        schedule_retry()
    end)
    sub = this
end

local function fetch()
    if not require("herdr.connection").active then
        return -- nothing to fetch until you connect
    end
    if refreshing then
        refresh_again = true
        return
    end
    refreshing = true
    local my_epoch = epoch
    api.request("session.snapshot", nil, function(err, result)
        if my_epoch ~= epoch then
            return -- from a connection that has since been replaced
        end
        refreshing = false
        if err then
            M.error = err
            emit()
            schedule_retry()
        else
            M.error = nil
            M.snapshot = result.snapshot
            local present = {}
            for _, p in ipairs(M.snapshot.panes or {}) do
                present[p.pane_id] = true
                if p.agent_status ~= "done" then
                    M.seen[p.pane_id] = nil -- working again (or seen in Herdr)
                end
            end
            for id in pairs(M.seen) do
                if not present[id] then
                    M.seen[id] = nil
                end
            end
            emit()
            if active then
                ensure_subscription(M.snapshot)
            end
        end
        if refresh_again then
            refresh_again = false
            fetch()
        end
    end)
end

--- Re-fetch the snapshot soon (debounced).
function M.refresh()
    active = true
    if refresh_timer then
        refresh_timer:stop()
    else
        refresh_timer = assert(vim.uv.new_timer())
    end
    refresh_timer:start(config.options.refresh_debounce_ms, 0, vim.schedule_wrap(fetch))
end

--- Start tracking the session (idempotent).
function M.start()
    if not active then
        M.refresh()
    end
end

---@param fn fun(snapshot: table?, err: string?)
function M.on_change(fn)
    listeners[#listeners + 1] = fn
    return function()
        for i, f in ipairs(listeners) do
            if f == fn then
                table.remove(listeners, i)
                return
            end
        end
    end
end

function M.stop()
    active = false
    if sub then
        local old = sub
        sub = nil
        old.close()
    end
end

--- Forget the current session entirely (e.g. before switching servers).
function M.reset()
    M.stop()
    sub_key = nil
    if refresh_timer then
        refresh_timer:stop()
    end
    if retry_timer then
        pcall(function()
            retry_timer:stop()
        end)
        retry_timer = nil
    end
    epoch = epoch + 1
    refreshing, refresh_again = false, false
    M.seen = {}
    M.snapshot = nil
    M.error = nil
    emit()
end

--- Run fn(snapshot) once a snapshot is available (now, or after the next
--- successful fetch); fn(nil, err) if fetching fails first.
function M.when_snapshot(fn)
    if M.snapshot then
        return fn(M.snapshot)
    end
    local off
    off = M.on_change(function(snap, err)
        if snap or err then
            off()
            vim.schedule(function()
                fn(snap, err)
            end)
        end
    end)
    M.start()
end

-- Lookup helpers ------------------------------------------------------------

function M.pane(pane_id)
    for _, p in ipairs(M.snapshot and M.snapshot.panes or {}) do
        if p.pane_id == pane_id then
            return p
        end
    end
end

function M.tab(tab_id)
    for _, t in ipairs(M.snapshot and M.snapshot.tabs or {}) do
        if t.tab_id == tab_id then
            return t
        end
    end
end

function M.workspace(workspace_id)
    for _, w in ipairs(M.snapshot and M.snapshot.workspaces or {}) do
        if w.workspace_id == workspace_id then
            return w
        end
    end
end

--- Panes of a tab, in layout order when available.
function M.tab_panes(tab_id)
    local s = M.snapshot
    if not s then
        return {}
    end
    local by_id = {}
    for _, p in ipairs(s.panes or {}) do
        if p.tab_id == tab_id then
            by_id[p.pane_id] = p
        end
    end
    local out = {}
    for _, l in ipairs(s.layouts or {}) do
        if l.tab_id == tab_id then
            for _, lp in ipairs(l.panes or {}) do
                if by_id[lp.pane_id] then
                    out[#out + 1] = by_id[lp.pane_id]
                    by_id[lp.pane_id] = nil
                end
            end
        end
    end
    for _, p in pairs(by_id) do
        out[#out + 1] = p
    end
    return out
end

-- Statuses, drawn like Herdr: yellow working, red blocked, teal done (finished,
-- not seen yet), green idle (finished and seen), gray unknown. Glyph style
-- follows Herdr's [ui] status_indicators ("dots" by default, or "symbols").
local GLYPHS = {
    dots = { working = "●", blocked = "●", done = "●", idle = "○", unknown = "·" },
    symbols = { working = "◐", blocked = "×", done = "✓", idle = "○", unknown = "·" },
}
local HL = {
    working = "HerdrWorking",
    blocked = "HerdrBlocked",
    done = "HerdrDone",
    idle = "HerdrIdle",
    unknown = "HerdrUnknown",
}
local PRIORITY = { blocked = 4, done = 3, working = 2, idle = 1, unknown = 0 }

local glyph_style ---@type string?
local function glyphs()
    if not glyph_style then
        local style = config.options.status_style
        if style == nil or style == "herdr" then
            style = require("herdr.herdr_config").section("ui").status_indicators
        end
        glyph_style = GLYPHS[style] and style or "dots"
    end
    return GLYPHS[glyph_style]
end

--- { icon, hl } for a status.
function M.status(s)
    s = HL[s or "unknown"] and s or "unknown"
    return { icon = glyphs()[s], hl = HL[s] }
end

function M.status_icon(s)
    return M.status(s).icon
end

-- Seen tracking: Herdr only marks a finished agent "seen" when its tab is
-- focused in Herdr itself, so herdr-nvim also tracks what you looked at.
M.seen = {} ---@type table<string, boolean> pane_id -> seen in Neovim since it finished

--- A pane's status as shown: "done" becomes "idle" once seen in Neovim.
function M.pane_status(p)
    local s = p.agent_status or "unknown"
    if s == "done" and M.seen[p.pane_id] then
        return "idle"
    end
    return s
end

--- The most important of several statuses (Herdr's order: blocked > done >
--- working > idle > unknown).
function M.aggregate(statuses)
    local best = "unknown"
    for _, s in ipairs(statuses) do
        if (PRIORITY[s] or 0) > PRIORITY[best] then
            best = s
        end
    end
    return best
end

local function aggregate_panes(pred)
    local list = {}
    for _, p in ipairs(M.snapshot and M.snapshot.panes or {}) do
        if pred(p) then
            list[#list + 1] = M.pane_status(p)
        end
    end
    return M.aggregate(list)
end

function M.workspace_status(workspace_id)
    return aggregate_panes(function(p)
        return p.workspace_id == workspace_id
    end)
end

function M.tab_status(tab_id)
    return aggregate_panes(function(p)
        return p.tab_id == tab_id
    end)
end

--- Mark a finished pane as seen (it was viewed in Neovim). With
--- `mark_seen = "herdr"`, also tell Herdr (this moves Herdr's focus).
function M.mark_seen(pane_id)
    local p = M.pane(pane_id)
    if not p or p.agent_status ~= "done" or M.seen[pane_id] then
        return
    end
    M.seen[pane_id] = true
    emit()
    if config.options.mark_seen == "herdr" then
        api.request("pane.focus", { pane_id = pane_id }, function() end)
    end
end

--- Best human-readable label for a pane.
function M.pane_label(p)
    if p.label and p.label ~= "" then
        return p.label
    end
    local cwd = p.foreground_cwd or p.cwd
    local dir = cwd and vim.fn.fnamemodify(cwd, ":t") or nil
    -- Agent titles mostly repeat the agent name and directory ("π - repo"),
    -- so for agent panes the directory is the most useful label.
    if p.agent and dir then
        return dir
    end
    local title = p.title or p.terminal_title_stripped
    if title and title ~= "" then
        return title
    end
    return dir or p.pane_id
end

return M
