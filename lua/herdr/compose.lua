-- Compose agent input in a real Neovim buffer.
--
-- A terminal buffer is read-only and the agent draws its own input box, so
-- editing happens in a compose split instead: full Neovim editing (motions,
-- operators, registers, undo, completion), then send it to the agent.
--   <CR> (normal) / <C-s>   send as a prompt (Herdr's agent.prompt: pasted as
--                           one block, then submitted; shells get text + Enter)
--   <C-g>                   paste into the agent's input without submitting
--   q                       close, keeping the draft (one per terminal)

local api = require("herdr.api")
local config = require("herdr.config")
local state = require("herdr.state")

local M = {}

local drafts = {} ---@type table<string, integer> pane_id -> compose buffer

local function pane_name(pane)
    local name = state.pane_label(pane)
    local tab = state.tab(pane.tab_id)
    if tab and tab.label and not tab.label:match("^%d+$") and #state.tab_panes(tab.tab_id) <= 1 then
        name = tab.label
    end
    return name
end

local function text_of(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return vim.trim(table.concat(lines, "\n"))
end

--- Close the compose window and go back to the terminal it belongs to.
local function close(buf, insert)
    local term_win = vim.b[buf].herdr_compose_from
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_close, win, true)
    end
    if term_win and vim.api.nvim_win_is_valid(term_win) then
        vim.api.nvim_set_current_win(term_win)
        if insert and vim.bo[vim.api.nvim_win_get_buf(term_win)].buftype == "terminal" then
            vim.cmd("startinsert")
        end
    end
end

local function sent(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.bo[buf].modified = false
    close(buf, true)
end

--- Send the draft as a prompt.
function M.submit(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local pane_id = vim.b[buf].herdr_pane_id
    local text = text_of(buf)
    if text == "" then
        return close(buf, true)
    end
    local pane = state.pane(pane_id)
    local function fallback()
        -- No agent in this pane (e.g. a shell): type it and press Enter.
        api.request("pane.send_text", { pane_id = pane_id, text = text .. "\r" }, function(err)
            if err then
                return vim.notify("herdr: sending failed: " .. err, vim.log.levels.ERROR)
            end
            sent(buf)
        end)
    end
    if not (pane and pane.agent) then
        return fallback()
    end
    api.request("agent.prompt", { target = pane_id, text = text }, function(err)
        if err then
            return fallback()
        end
        sent(buf)
    end)
end

--- Paste the draft into the agent's own input box without submitting.
function M.paste(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local text = text_of(buf)
    if text == "" then
        return close(buf, true)
    end
    local payload = "\27[200~" .. text .. "\27[201~" -- bracketed paste: one block, no submit
    api.request("pane.send_text", { pane_id = vim.b[buf].herdr_pane_id, text = payload }, function(err)
        if err then
            return vim.notify("herdr: paste failed: " .. err, vim.log.levels.ERROR)
        end
        sent(buf)
    end)
end

local function draft_buf(pane)
    local buf = drafts[pane.pane_id]
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    -- Markdown highlighting is a nicety: never fail over a missing parser.
    pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })
    pcall(vim.api.nvim_buf_set_name, buf, "herdr-compose://" .. pane.pane_id)
    vim.b[buf].herdr_pane_id = pane.pane_id
    drafts[pane.pane_id] = buf
    require("herdr.keys").apply(buf, config.options.compose.keys, {
        send = {
            desc = "Send to agent",
            fn = function()
                vim.cmd("stopinsert")
                M.submit(buf)
            end,
        },
        paste = {
            desc = "Paste into agent input (no submit)",
            fn = function()
                vim.cmd("stopinsert")
                M.paste(buf)
            end,
        },
        close = {
            desc = "Close (keep draft)",
            fn = function()
                close(buf, false)
            end,
        },
    })
    return buf
end

--- The pane to compose for when none is given: the current window's terminal,
--- else the last herdr terminal used in this tab. Returns pane_id, window
--- showing it (or the current window).
local function current_target()
    local cur = vim.api.nvim_get_current_win()
    local id = vim.b.herdr_pane_id
    if id and not vim.b.herdr_compose_from then
        return id, cur
    end
    id = require("herdr.terminal").last_pane[vim.api.nvim_get_current_tabpage()]
    if not (id and state.pane(id)) then
        return nil
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.b[vim.api.nvim_win_get_buf(win)].herdr_pane_id == id then
            return id, win
        end
    end
    return id, cur
end

--- Ask which agent to compose for (agents first, then other terminals).
local function pick_target(cb)
    local panes = {}
    for _, p in ipairs(state.snapshot and state.snapshot.panes or {}) do
        panes[#panes + 1] = p
    end
    table.sort(panes, function(a, b)
        return (a.agent and 0 or 1) < (b.agent and 0 or 1)
    end)
    vim.ui.select(panes, {
        prompt = "herdr: compose for",
        format_item = function(p)
            local ws = state.workspace(p.workspace_id)
            local agent = p.display_agent or p.agent
            return string.format(
                "%s %s%s  [%s]",
                state.status_icon(state.pane_status(p)),
                pane_name(p),
                agent and ("  " .. agent) or "",
                ws and ws.label or p.workspace_id
            )
        end,
    }, function(p)
        if p then
            cb(p.pane_id)
        end
    end)
end

--- Open the compose split: for `pane_id`, else the terminal in the current
--- window, else the last herdr terminal used in this tab, else ask.
function M.open(pane_id)
    local from_win = vim.api.nvim_get_current_win()
    if not pane_id then
        local id, win = current_target()
        if not id then
            local connection = require("herdr.connection")
            return connection.with_connection(function()
                state.when_snapshot(function(snap)
                    if snap then
                        pick_target(M.open)
                    end
                end)
            end)
        end
        pane_id, from_win = id, win or from_win
        vim.api.nvim_set_current_win(from_win)
    end
    local pane = state.pane(pane_id)
    if not pane then
        return vim.notify("herdr: unknown pane " .. tostring(pane_id), vim.log.levels.WARN)
    end
    -- Composing for a picked agent that is open somewhere: split under it.
    local shown = require("herdr.terminal").buffers[pane.terminal_id]
    local shown_win = shown and vim.fn.win_findbuf(shown)[1]
    if shown_win and vim.api.nvim_win_get_tabpage(shown_win) == vim.api.nvim_get_current_tabpage() then
        from_win = shown_win
        vim.api.nvim_set_current_win(shown_win)
    end
    local buf = draft_buf(pane)
    vim.b[buf].herdr_compose_from = from_win
    local existing = vim.fn.win_findbuf(buf)[1]
    if existing then
        vim.api.nvim_set_current_win(existing)
    else
        vim.cmd("belowright " .. (config.options.compose.height or 8) .. "split")
        vim.api.nvim_win_set_buf(0, buf)
        local wo = vim.wo[0][0]
        wo.winfixheight = true
        local by = require("herdr.keys").by_action(config.options.compose.keys)
        local hints = {}
        for _, h in ipairs({ { "send", "send" }, { "paste", "paste without sending" }, { "close", "close" } }) do
            if by[h[1]] then
                hints[#hints + 1] = table.concat(by[h[1]], "/") .. " " .. h[2]
            end
        end
        wo.winbar = "%#HerdrAgentIcon# ✎ %*%#HerdrFocused#"
            .. pane_name(pane):gsub("%%", "%%%%")
            .. "%*%#HerdrMuted#   "
            .. table.concat(hints, " · "):gsub("%%", "%%%%")
            .. "%*"
    end
    vim.cmd("startinsert!")
end

return M
