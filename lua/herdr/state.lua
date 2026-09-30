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
            vim.notify("herdr.nvim listener error: " .. tostring(err), vim.log.levels.ERROR)
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
    this = api.subscribe(subs, function()
        M.refresh()
    end, function(err)
        if sub ~= this then
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
    if refreshing then
        refresh_again = true
        return
    end
    refreshing = true
    api.request("session.snapshot", nil, function(err, result)
        refreshing = false
        if err then
            M.error = err
            emit()
            schedule_retry()
        else
            M.error = nil
            M.snapshot = result.snapshot
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

M.STATUS = {
    working = { icon = "\u{25CF}", hl = "HerdrWorking" }, -- "●"
    blocked = { icon = "!", hl = "HerdrBlocked" },
    done = { icon = "\u{2713}", hl = "HerdrDone" }, -- "✓"
    idle = { icon = "\u{25CB}", hl = "HerdrIdle" }, -- "○"
    unknown = { icon = " ", hl = "HerdrIdle" },
}

function M.status(s)
    return M.STATUS[s or "unknown"] or M.STATUS.unknown
end

function M.status_icon(s)
    return M.status(s).icon
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
