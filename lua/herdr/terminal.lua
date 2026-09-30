-- Herdr panes as Neovim :terminal buffers (via `herdr terminal attach`).

local state = require("herdr.state")
local transport = require("herdr.transport")

local M = {}

---@type table<string, integer> terminal_id -> bufnr
M.buffers = {}

local ATTACH_CONFLICT = "already has an attached client"

local function is_live(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return false
    end
    local chan = vim.bo[buf].channel
    return chan and chan > 0 and vim.fn.jobwait({ chan }, 0)[1] == -1
end

local DETACH_KEYS = "\2q" -- Ctrl-B q: herdr's own detach sequence

--- Detach cleanly instead of just killing the attach process.
---
--- Used on exit. Buffer deletion (:bd!) kills the job before any autocmd
--- runs; that path is covered by the cleanup from transport.attach_cmd.
---@param buf integer
---@param timeout_ms? integer
function M.detach(buf, timeout_ms)
    if not is_live(buf) then
        return
    end
    local chan = vim.bo[buf].channel
    pcall(vim.fn.chansend, chan, DETACH_KEYS)
    local exited = vim.wait(timeout_ms or 1500, function()
        return vim.fn.jobwait({ chan }, 0)[1] ~= -1
    end, 20)
    if not exited then
        pcall(vim.fn.jobstop, chan)
    end
end

function M.detach_all()
    for _, buf in pairs(M.buffers) do
        M.detach(buf, 1000)
    end
end

--- Detach and remove every herdr terminal buffer (e.g. when switching servers).
function M.close_all()
    if package.loaded["herdr.history"] then
        require("herdr.history").forget_all()
    end
    M.detach_all()
    for terminal_id, buf in pairs(M.buffers) do
        M.buffers[terminal_id] = nil
        if vim.api.nvim_buf_is_valid(buf) then
            M.remove_buffer(buf)
        end
    end
end

--- Buffers currently attached, keyed by pane_id.
function M.attached_panes()
    local out = {}
    for terminal_id, buf in pairs(M.buffers) do
        if is_live(buf) then
            out[vim.b[buf].herdr_pane_id or terminal_id] = buf
        end
    end
    return out
end

--- Pick or create the window to show a pane in.
---@param how "current"|"vsplit"|"split"|"tab"
local function target_window(how)
    if how == "tab" then
        vim.cmd("tabnew")
        return vim.api.nvim_get_current_win()
    end
    -- Never replace the sidebar itself: use the most recent normal window.
    local win = vim.api.nvim_get_current_win()
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "herdr" then
        local prev = vim.fn.win_getid(vim.fn.winnr("#"))
        if prev ~= 0 and prev ~= win and vim.bo[vim.api.nvim_win_get_buf(prev)].filetype ~= "herdr" then
            win = prev
        else
            for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if
                    vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "herdr"
                    and vim.api.nvim_win_get_config(w).relative == ""
                then
                    win = w
                    break
                end
            end
            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "herdr" then
                vim.cmd("rightbelow vsplit")
                win = vim.api.nvim_get_current_win()
                how = "current"
            end
        end
    end
    vim.api.nvim_set_current_win(win)
    if how == "vsplit" then
        vim.cmd("rightbelow vsplit")
    elseif how == "split" then
        vim.cmd("rightbelow split")
    end
    return vim.api.nvim_get_current_win()
end

local config = require("herdr.config")
local cached_style ---@type table? resolved once; winbar() runs on every redraw

--- Buffer-local terminal keys: double <Esc> leaves terminal mode (a single
--- <Esc> is still sent to the agent immediately), like snacks.nvim terminals.
local NAV = {
    left = { wincmd = "h", tmux = "TmuxNavigateLeft", smart = "move_cursor_left" },
    down = { wincmd = "j", tmux = "TmuxNavigateDown", smart = "move_cursor_down" },
    up = { wincmd = "k", tmux = "TmuxNavigateUp", smart = "move_cursor_up" },
    right = { wincmd = "l", tmux = "TmuxNavigateRight", smart = "move_cursor_right" },
}

--- Move to the neighboring window, through whatever navigator the user has:
--- vim-tmux-navigator, smart-splits.nvim, or plain window commands.
function M.navigate(dir)
    local n = NAV[dir]
    if vim.fn.exists(":" .. n.tmux) == 2 then
        return vim.cmd(n.tmux)
    end
    local ok, smart = pcall(require, "smart-splits")
    if ok and type(smart[n.smart]) == "function" then
        return smart[n.smart]()
    end
    vim.cmd("wincmd " .. n.wincmd)
end

-- History ---------------------------------------------------------------------
--
-- `herdr terminal attach` repaints the pane's screen in place, so the terminal
-- buffer only ever holds one screen. Scrolling up (or searching) opens a local,
-- cached copy of the pane's history instead (see herdr.history), where
-- everything is native Neovim.

local function wheel_lines()
    return tonumber((vim.o.mousescroll or ""):match("ver:(%d+)")) or 3
end

local function setup_history_keys(buf)
    if not config.options.terminal.history then
        return
    end
    local history = require("herdr.history")
    local function map(modes, lhs, fn, desc)
        vim.keymap.set(modes, lhs, fn, { buffer = buf, desc = desc })
    end
    local function motion(keys)
        return function()
            history.open(vim.v.count > 0 and (vim.v.count .. keys) or keys)
        end
    end
    map({ "n", "t" }, "<ScrollWheelUp>", function()
        history.open(wheel_lines() .. "<C-y>")
    end, "Herdr history (scroll up)")
    map("n", "<C-u>", motion("<C-u>"), "Herdr history (half page up)")
    map("n", "<C-b>", motion("<C-b>"), "Herdr history (page up)")
    map("n", "<PageUp>", motion("<C-b>"), "Herdr history (page up)")
    map("n", "<C-y>", motion("<C-y>"), "Herdr history (line up)")
    map("n", "k", motion("k"), "Herdr history (up)")
    map("n", "gg", motion("gg"), "Herdr history (top)")
    for _, key in ipairs({ "/", "?" }) do
        map("n", key, function()
            history.open("")
            vim.schedule(function()
                vim.api.nvim_feedkeys(key, "n", false)
            end)
        end, "Search herdr history")
    end
end

local function setup_keys(buf)
    setup_history_keys(buf)
    for dir, lhs in pairs(config.options.terminal.navigation or {}) do
        if lhs and NAV[dir] then
            vim.keymap.set("t", lhs, function()
                M.navigate(dir)
            end, { buffer = buf, desc = "Navigate " .. dir })
        end
    end
    if config.options.terminal.esc ~= "passthrough" then
        vim.keymap.set("t", "<Esc>", "<C-\\><C-n>", { buffer = buf, desc = "Normal mode" })
    end
end

--- Winbar for herdr terminal windows: status, agent, name, space.
function M.winbar()
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local pane = state.pane(vim.b[buf].herdr_pane_id or "")
    if not pane then
        return " " .. (vim.b[buf].herdr_pane_id or "herdr")
    end
    cached_style = cached_style or require("herdr.style").get()
    local style = cached_style
    local st = state.status(pane.agent_status)
    local agent = pane.display_agent or pane.agent
    local ws = state.workspace(pane.workspace_id)
    local tab = state.tab(pane.tab_id)
    local name = state.pane_label(pane)
    if tab and tab.label and not tab.label:match("^%d+$") and #state.tab_panes(tab.tab_id) == 1 then
        name = tab.label
    end
    local esc = function(t)
        return (t or ""):gsub("%%", "%%%%")
    end
    local parts = {
        "%#" .. st.hl .. "# " .. st.icon .. " %*",
        "%#"
            .. (agent and "HerdrAgentIcon" or "HerdrShellIcon")
            .. "#"
            .. (agent and style.icons.agent or style.icons.shell)
            .. "%*",
        "%#HerdrFocused#" .. esc(name) .. "%*",
    }
    if agent then
        parts[#parts + 1] = "%#HerdrMuted#  " .. esc(agent) .. "%*"
    end
    if pane.agent_status and pane.agent_status ~= "unknown" then
        parts[#parts + 1] = "%#" .. st.hl .. "#  " .. pane.agent_status .. "%*"
    end
    if vim.b[buf].herdr_history then
        parts[#parts + 1] = "%#HerdrAttached#  󰋚 history  (i: live)%*"
    end
    parts[#parts + 1] = "%=%#HerdrMuted#" .. esc(ws and ws.label or pane.workspace_id) .. " %*"
    return table.concat(parts)
end

--- Per-window decorations for a herdr terminal window.
function M.decorate(win)
    if config.options.terminal.winbar and vim.api.nvim_win_is_valid(win) then
        require("herdr.style").define_highlights()
        vim.wo[win][0].winbar = "%{%v:lua.require'herdr.terminal'.winbar()%}"
    end
end

--- Buffer name: unique per pane, and ending in a readable label so tab and
--- buffer lines (which show the last path component) say which agent it is.
local function buf_name(pane)
    local label = state.pane_label(pane)
    local tab = state.tab(pane.tab_id)
    if tab and tab.label and not tab.label:match("^%d+$") and #state.tab_panes(tab.tab_id) <= 1 then
        label = tab.label
    end
    label = label:gsub("[/\\]", "-")
    return string.format("herdr://%s/%s/%s", transport.describe(), pane.pane_id, label)
end

local function start(buf, pane, takeover)
    local terminal_id = pane.terminal_id
    local cmd, cleanup, env = transport.attach_cmd(terminal_id, takeover)
    vim.api.nvim_buf_call(buf, function()
        vim.fn.jobstart(cmd, {
            term = true,
            env = env,
            on_exit = function(_, code)
                vim.schedule(function()
                    cleanup()
                    vim.api.nvim_exec_autocmds(
                        "User",
                        { pattern = "HerdrDetach", data = { buf = buf, pane_id = pane.pane_id } }
                    )
                    if not vim.api.nvim_buf_is_valid(buf) then
                        return
                    end
                    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
                    if code ~= 0 and text:find(ATTACH_CONFLICT, 1, true) then
                        M.offer_takeover(buf, pane)
                    end
                end)
            end,
        })
    end)
    -- Set after jobstart: `term = true` renames the buffer to term://...
    M.buffers[terminal_id] = buf
    vim.b[buf].herdr_pane_id = pane.pane_id
    vim.b[buf].herdr_terminal_id = terminal_id
    pcall(vim.api.nvim_buf_set_name, buf, buf_name(pane))
    vim.bo[buf].buflisted = true
    setup_keys(buf)
    vim.api.nvim_exec_autocmds("User", { pattern = "HerdrAttach", data = { buf = buf, pane_id = pane.pane_id } })
end

--- Replace a dead/conflicting terminal buffer with a fresh (takeover) attach.
function M.offer_takeover(buf, pane)
    vim.ui.select({ "Take over", "Cancel" }, {
        prompt = pane.pane_id .. " is attached elsewhere (another `herdr terminal attach`).",
    }, function(choice)
        if choice ~= "Take over" or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local fresh = vim.api.nvim_create_buf(true, false)
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            vim.api.nvim_win_set_buf(win, fresh)
        end
        vim.api.nvim_buf_delete(buf, { force = true })
        start(fresh, pane, true)
        vim.schedule(function()
            if vim.api.nvim_get_current_buf() == fresh then
                vim.cmd("startinsert")
            end
        end)
    end)
end

--- Open a Herdr pane in a Neovim terminal (reusing a live attach if present).
---@param pane string|table pane id, or a pane object (e.g. freshly created)
---@param opts? { how?: "current"|"vsplit"|"split"|"tab", takeover?: boolean, enter?: boolean }
function M.open(pane, opts)
    opts = opts or {}
    if type(pane) == "string" then
        local id = pane
        pane = state.pane(id)
        if not pane then
            return vim.notify("herdr: unknown pane " .. id, vim.log.levels.WARN)
        end
    end
    local existing = M.buffers[pane.terminal_id]
    local win = target_window(opts.how or "current")
    if is_live(existing) and not opts.takeover then
        vim.api.nvim_win_set_buf(win, existing)
    else
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(win, buf)
        if existing and vim.api.nvim_buf_is_valid(existing) then
            pcall(vim.api.nvim_buf_delete, existing, { force = true })
        end
        start(buf, pane, opts.takeover)
    end
    M.decorate(win)
    if opts.enter ~= false then
        vim.cmd("startinsert")
    end
    return win
end

--- Open several panes tiled in a new tab (a grid of roughly square cells).
---@param panes table[] pane objects
function M.open_many(panes)
    if #panes == 0 then
        return vim.notify("herdr: nothing to open", vim.log.levels.INFO)
    end
    if #panes == 1 then
        return M.open(panes[1], { how = "tab" })
    end
    vim.cmd("tabnew")
    local scratch = vim.api.nvim_get_current_buf()
    local cols = math.ceil(math.sqrt(#panes))
    local rows = math.ceil(#panes / cols)
    -- Build the columns, then split each column into rows.
    local columns = { vim.api.nvim_get_current_win() }
    for _ = 2, cols do
        vim.api.nvim_set_current_win(columns[#columns])
        vim.cmd("rightbelow vsplit")
        columns[#columns + 1] = vim.api.nvim_get_current_win()
    end
    local cells = {}
    for c, col_win in ipairs(columns) do
        local in_col = math.min(rows, #panes - (c - 1) * rows)
        vim.api.nvim_set_current_win(col_win)
        cells[#cells + 1] = col_win
        for _ = 2, in_col do
            vim.cmd("rightbelow split")
            cells[#cells + 1] = vim.api.nvim_get_current_win()
        end
    end
    vim.cmd("wincmd =")
    for i, pane in ipairs(panes) do
        if cells[i] then
            vim.api.nvim_set_current_win(cells[i])
            M.open(pane, { how = "current", enter = false })
        end
    end
    vim.api.nvim_set_current_win(cells[1])
    -- Drop the empty buffer :tabnew created, now that terminals replaced it.
    if
        vim.api.nvim_buf_is_valid(scratch)
        and vim.api.nvim_buf_get_name(scratch) == ""
        and not vim.bo[scratch].modified
        and #vim.fn.win_findbuf(scratch) == 0
    then
        pcall(vim.api.nvim_buf_delete, scratch, {})
    end
    if config.options.terminal.auto_insert then
        vim.cmd("startinsert")
    end
end

--- Remove a buffer without closing the windows showing it.
function M.remove_buffer(buf)
    if package.loaded["snacks"] and Snacks and Snacks.bufdelete then
        return Snacks.bufdelete({ buf = buf, force = true })
    end
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_call(w, function()
            local alt = vim.fn.bufnr("#")
            if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
                vim.api.nvim_win_set_buf(w, alt)
            else
                vim.api.nvim_win_set_buf(w, vim.api.nvim_create_buf(true, false))
            end
        end)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

--- Close terminal buffers whose herdr pane no longer exists (closed from the
--- tree, from herdr, or by its process exiting).
function M.prune()
    if not state.snapshot then
        return
    end
    for terminal_id, buf in pairs(M.buffers) do
        if not vim.api.nvim_buf_is_valid(buf) then
            M.buffers[terminal_id] = nil
        else
            local pane = state.pane(vim.b[buf].herdr_pane_id or "")
            if not pane and not is_live(buf) then
                M.buffers[terminal_id] = nil
                M.remove_buffer(buf)
            elseif pane then
                -- Keep the buffer name in sync with renames (and with new panes
                -- whose tab label was not known yet when they were opened).
                local name = buf_name(pane)
                if vim.api.nvim_buf_get_name(buf) ~= name then
                    pcall(vim.api.nvim_buf_set_name, buf, name)
                end
            end
        end
    end
end

state.on_change(function()
    vim.schedule(function()
        M.prune()
        -- Statuses changed: repaint winbars.
        if config.options.terminal.winbar then
            pcall(vim.cmd, "redrawstatus!")
        end
    end)
end)

local term_group = vim.api.nvim_create_augroup("herdr_terminal_ui", { clear = true })
vim.api.nvim_create_autocmd("BufWinEnter", {
    group = term_group,
    pattern = { "herdr://*", "herdr-history://*" },
    callback = function(ev)
        if vim.b[ev.buf].herdr_terminal_id or vim.b[ev.buf].herdr_history then
            M.decorate(vim.api.nvim_get_current_win())
        end
    end,
})
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = term_group,
    pattern = "herdr://*",
    callback = function(ev)
        if config.options.terminal.auto_insert and vim.b[ev.buf].herdr_terminal_id and is_live(ev.buf) then
            vim.schedule(function()
                if vim.api.nvim_get_current_buf() == ev.buf and vim.fn.mode() ~= "t" then
                    vim.cmd("startinsert")
                end
            end)
        end
    end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
    group = term_group,
    pattern = "herdr://*",
    callback = function(ev)
        local id = vim.b[ev.buf].herdr_pane_id
        if id and package.loaded["herdr.history"] then
            require("herdr.history").forget(id)
        end
    end,
})
vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("herdr_terminal", { clear = true }),
    pattern = "HerdrDetach",
    callback = function()
        -- The pane may have just been closed; re-check against a fresh snapshot.
        state.refresh()
    end,
})

return M
