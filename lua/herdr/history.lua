-- Local, native scrollback for herdr terminals.
--
-- `herdr terminal attach` repaints a pane's screen in place, so its terminal
-- buffer only holds the current screen; the history lives on the Herdr server.
-- This module keeps a local copy of a pane's history and shows it in a
-- read-only terminal buffer (colors kept), so scrolling, search and yank are
-- plain Neovim with no network round trips.
--
-- Herdr's API returns at most the latest 1000 lines per read, with no offset,
-- so the cache grows by merging: each read's lines are aligned with the cached
-- tail and only new lines are appended. While a pane is attached, reads happen
-- in the background (throttled, small reads, a full read when they no longer
-- overlap), so the cache keeps everything since the pane was first opened.
-- Only lines that scrolled above the screen are treated as settled; the screen
-- itself (agent status bars, input boxes) is replaced on every read.

local api = require("herdr.api")
local config = require("herdr.config")
local state = require("herdr.state")

local M = {}

local MAX_READ = 1000 -- Herdr's per-read cap
local ANCHOR = 12 -- lines used to align a read with the cache

---@class herdr.HistoryCache
---@field stable string[] settled lines (ANSI), oldest first
---@field plain string[] same lines without escape codes (for alignment)
---@field screen string[] the current screen (ANSI), replaced on every read
---@field rows integer screen height at the last read
---@field fetching boolean
---@field again boolean
---@field last integer uv.now() of the last read
---@field buf integer? history buffer
---@field dirty boolean cache changed since the buffer was built

local caches = {} ---@type table<string, herdr.HistoryCache>

local function strip(s)
    return (s:gsub("\27%[[%d;:?]*[ -/]*[@-~]", ""):gsub("\27%][^\7\27]*[\7]", ""):gsub("\r$", ""))
end

local function cache_for(pane_id)
    local c = caches[pane_id]
    if not c then
        c = { stable = {}, plain = {}, screen = {}, rows = 0, fetching = false, again = false, last = 0, dirty = true }
        caches[pane_id] = c
    end
    return c
end

--- Find where `plain` (a read, oldest first) continues the cache: the index
--- in `plain` of the first line after the cache's tail, or nil if no overlap.
local function find_continuation(c, plain)
    local n = #c.plain
    if n == 0 then
        return 1
    end
    local k = math.min(ANCHOR, n)
    local first = n - k + 1
    -- Search from the end: the newest match is the right one for repeated text.
    for j = #plain - k + 1, 1, -1 do
        local ok = true
        for i = 0, k - 1 do
            if plain[j + i] ~= c.plain[first + i] then
                ok = false
                break
            end
        end
        if ok then
            return j + k
        end
    end
end

--- Merge a read (ANSI text, oldest first) into the cache. Returns true when it
--- overlapped (or the cache was empty), false when there was a gap.
local function merge(c, text, rows, full)
    local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
    -- The last `rows` lines are the screen; everything above it has settled.
    local split = math.max(0, #lines - rows)
    local plain = {}
    for i = 1, split do
        plain[i] = strip(lines[i])
    end
    local from = find_continuation(c, plain)
    if not from then
        if not full then
            return false -- ask for a full read before giving up
        end
        -- Too much output since the last read: mark the gap.
        local marker = "\27[2m··· earlier lines not loaded (more output than Herdr returns per read) ···\27[0m"
        table.insert(c.stable, marker)
        table.insert(c.plain, strip(marker))
        from = 1
    end
    for i = from, split do
        c.stable[#c.stable + 1] = lines[i]
        c.plain[#c.plain + 1] = plain[i]
    end
    local screen = {}
    for i = split + 1, #lines do
        screen[#screen + 1] = lines[i]
    end
    while #screen > 0 and strip(screen[#screen]):match("^%s*$") do
        table.remove(screen) -- blank rows under the content
    end
    c.screen = screen
    c.rows = rows
    c.dirty = true
    local limit = config.options.terminal.history_limit or 100000
    local excess = #c.stable - limit
    if excess > 0 then
        for _ = 1, excess do
            table.remove(c.stable, 1)
            table.remove(c.plain, 1)
        end
    end
    return true
end

--- Fetch and merge a pane's history. cb(err) when done.
function M.sync(pane_id, cb)
    cb = cb or function() end
    local c = cache_for(pane_id)
    if c.fetching then
        c.again = true
        return cb(nil)
    end
    local pane = state.pane(pane_id)
    local rows = pane and pane.scroll and pane.scroll.viewport_rows or 50
    c.fetching = true
    local function read(lines, full)
        local params = { pane_id = pane_id, source = "recent", lines = lines, format = "ansi", strip_ansi = false }
        api.request("pane.read", params, function(err, res)
            local text = res and res.read and res.read.text
            if err or not text then
                c.fetching = false
                return cb(err or "no text")
            end
            if not merge(c, text, rows, full) then
                return read(MAX_READ, true)
            end
            c.fetching = false
            c.last = vim.uv.now()
            if c.again then
                c.again = false
                return M.sync(pane_id, cb)
            end
            cb(nil)
        end)
    end
    -- Small reads once the cache has content; a full read the first time.
    if #c.stable == 0 then
        read(MAX_READ, true)
    else
        read(math.min(MAX_READ, rows * 3), false)
    end
end

-- History buffer ---------------------------------------------------------------

--- Run fn once a freshly fed terminal buffer has processed its content
--- (Neovim parses terminal output asynchronously).
local function when_ready(buf, fn)
    local want = vim.b[buf].herdr_expected_lines or 0
    local last, stable, tries = -1, 0, 0
    local function check()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local n = vim.api.nvim_buf_line_count(buf)
        stable = (n == last) and stable + 1 or 0
        last = n
        tries = tries + 1
        if (n >= want and stable >= 1) or tries > 100 then
            return fn()
        end
        vim.defer_fn(check, 10)
    end
    check()
end

local function all_lines(c)
    local out = {}
    for _, l in ipairs(c.stable) do
        out[#out + 1] = l
    end
    for _, l in ipairs(c.screen) do
        out[#out + 1] = l
    end
    return out
end

--- (Re)build the history buffer from the cache. Returns the buffer.
local function build(pane_id, live_buf)
    local c = cache_for(pane_id)
    if c.buf and vim.api.nvim_buf_is_valid(c.buf) and not c.dirty then
        return c.buf
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].scrollback = 100000
    local chan = vim.api.nvim_open_term(buf, {})
    vim.api.nvim_chan_send(chan, table.concat(all_lines(c), "\r\n"))
    vim.b[buf].herdr_pane_id = pane_id
    vim.b[buf].herdr_history = true
    vim.b[buf].herdr_live_buf = live_buf
    vim.b[buf].herdr_expected_lines = #all_lines(c)
    local prev = c.buf
    if prev and vim.api.nvim_buf_is_valid(prev) then
        pcall(vim.api.nvim_buf_set_name, prev, "herdr-history://" .. pane_id .. " (old)")
    end
    pcall(vim.api.nvim_buf_set_name, buf, "herdr-history://" .. pane_id)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].buflisted = false
    M.setup_keys(buf)
    local old = c.buf
    c.buf, c.dirty = buf, false
    if old and vim.api.nvim_buf_is_valid(old) then
        -- Swap windows showing the old copy, keeping their distance from the bottom.
        for _, win in ipairs(vim.fn.win_findbuf(old)) do
            local from_bottom = vim.api.nvim_buf_line_count(old) - vim.api.nvim_win_get_cursor(win)[1]
            local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
            local top_from_bottom = vim.api.nvim_buf_line_count(old) - view.topline
            when_ready(buf, function()
                if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= old then
                    return
                end
                vim.api.nvim_win_set_buf(win, buf)
                M.style_window(win)
                local n = vim.api.nvim_buf_line_count(buf)
                pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, n - from_bottom), 0 })
                vim.api.nvim_win_call(win, function()
                    vim.fn.winrestview({ topline = math.max(1, n - top_from_bottom) })
                end)
            end)
        end
        when_ready(buf, function()
            vim.schedule(function()
                pcall(vim.api.nvim_buf_delete, old, { force = true })
            end)
        end)
    end
    return buf
end

--- Style a window showing history like a terminal window (no numbers,
--- list chars or sign column), whatever the user's defaults are.
function M.style_window(win)
    local wo = vim.wo[win][0]
    wo.number, wo.relativenumber, wo.list, wo.spell = false, false, false, false
    wo.signcolumn, wo.foldcolumn, wo.statuscolumn = "no", "0", ""
    wo.cursorline = false
end

--- Show the live terminal again in `win` (from its history view).
function M.back(win, insert)
    win = win or vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local live = vim.b[buf].herdr_live_buf
    if live and vim.api.nvim_buf_is_valid(live) then
        vim.api.nvim_win_set_buf(win, live)
        if insert then
            vim.cmd("startinsert")
        end
    end
end

function M.setup_keys(buf)
    require("herdr.terminal").setup_compose_key(buf)
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
    end
    for _, lhs in ipairs({ "i", "a", "I", "A" }) do
        map(lhs, function()
            M.back(nil, true)
        end, "Back to the live terminal (insert)")
    end
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        map(lhs, function()
            M.back(nil, false)
        end, "Back to the live terminal")
    end
end

--- Open the history view for the live herdr terminal in the current window,
--- then run `motion` (normal-mode keys, e.g. "\21" for <C-u>) there.
function M.open(motion)
    local win = vim.api.nvim_get_current_win()
    local live = vim.api.nvim_get_current_buf()
    local pane_id = vim.b[live].herdr_pane_id
    if not pane_id then
        return
    end
    if vim.fn.mode() == "t" then
        vim.cmd("stopinsert")
    end
    local c = cache_for(pane_id)
    local function show()
        local buf = build(pane_id, live)
        vim.api.nvim_win_set_buf(win, buf)
        M.style_window(win)
        require("herdr.terminal").decorate(win)
        when_ready(buf, function()
            if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
                return
            end
            vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
            if motion and motion ~= "" then
                vim.api.nvim_win_call(win, function()
                    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(motion, true, false, true))
                end)
            end
        end)
    end
    if #c.stable > 0 or #c.screen > 0 then
        show() -- instant from cache
        M.sync(pane_id, function()
            if c.dirty and c.buf and #vim.fn.win_findbuf(c.buf) > 0 then
                build(pane_id, live) -- refresh in place, keeping the position
            end
        end)
    else
        M.sync(pane_id, function(err)
            if err then
                return vim.notify("herdr: could not load history: " .. err, vim.log.levels.WARN)
            end
            show()
        end)
    end
end

--- Drop a pane's cache (pane closed, disconnected).
function M.forget(pane_id)
    local c = caches[pane_id]
    if c and c.buf and vim.api.nvim_buf_is_valid(c.buf) then
        for _, win in ipairs(vim.fn.win_findbuf(c.buf)) do
            M.back(win, false)
        end
        pcall(vim.api.nvim_buf_delete, c.buf, { force = true })
    end
    caches[pane_id] = nil
end

function M.forget_all()
    for id in pairs(caches) do
        M.forget(id)
    end
end

--- Background sync for attached panes, driven by session events and throttled.
local SYNC_INTERVAL_MS = 2000
local sync_timer

local function sync_attached()
    local terminal = package.loaded["herdr.terminal"]
    if not terminal or not config.options.terminal.history then
        return
    end
    local now = vim.uv.now()
    for pane_id in pairs(terminal.attached_panes()) do
        local c = caches[pane_id]
        if not c or now - c.last >= SYNC_INTERVAL_MS then
            M.sync(pane_id)
        end
    end
end

function M.setup()
    state.on_change(function(snapshot)
        if not snapshot then
            return
        end
        if not sync_timer then
            sync_timer = assert(vim.uv.new_timer())
        end
        if not sync_timer:is_active() then
            sync_timer:start(SYNC_INTERVAL_MS, 0, vim.schedule_wrap(sync_attached))
        end
    end)
end

-- for tests
M._merge = merge
M._cache_for = cache_for
M._caches = caches

return M
