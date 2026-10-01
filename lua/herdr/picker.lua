-- Spaces/agents picker.
--
-- With snacks.nvim: a tree-shaped picker (spaces > terminals) with live agent
-- status and a live preview of each terminal's screen (colors included).
-- Without snacks: falls back to vim.ui.select.

local api = require("herdr.api")
local state = require("herdr.state")
local terminal = require("herdr.terminal")

local M = {}

local function is_default_tab_label(label)
    return not label or label == "" or label:match("^%d+$") ~= nil
end

--- Flat item list in tree order: each space followed by its terminals.
function M.items()
    local s = state.snapshot
    local items = {}
    if not s then
        return items
    end
    for _, ws in ipairs(s.workspaces or {}) do
        local space = {
            kind = "space",
            workspace_id = ws.workspace_id,
            name = ws.label or ws.workspace_id,
            status = state.workspace_status(ws.workspace_id),
            focused = ws.focused,
        }
        items[#items + 1] = space
        local children = {}
        for _, tab in ipairs(s.tabs or {}) do
            if tab.workspace_id == ws.workspace_id then
                local panes = state.tab_panes(tab.tab_id)
                for _, p in ipairs(panes) do
                    local name = state.pane_label(p)
                    if #panes == 1 and not is_default_tab_label(tab.label) then
                        name = tab.label
                    end
                    children[#children + 1] = {
                        kind = "pane",
                        pane = p,
                        workspace_id = ws.workspace_id,
                        name = name,
                        agent = p.display_agent or p.agent,
                        status = state.pane_status(p),
                        cwd = p.foreground_cwd or p.cwd,
                        focused = p.focused and tab.focused and ws.focused,
                        parent = space,
                    }
                end
            end
        end
        for ci, child in ipairs(children) do
            child.last = ci == #children
            items[#items + 1] = child
        end
    end
    for i, item in ipairs(items) do
        item.idx = i
        local status = item.status and item.status ~= "unknown" and item.status or ""
        if item.kind == "space" then
            item.text = table.concat({ item.name, status }, " ")
        else
            item.text = table.concat({
                item.parent.name,
                item.name,
                item.agent or "",
                status,
                item.cwd and vim.fn.fnamemodify(item.cwd, ":t") or "",
            }, " ")
        end
    end
    return items
end

local function first_pane_of_space(workspace_id)
    local fallback
    for _, p in ipairs(state.snapshot and state.snapshot.panes or {}) do
        if p.workspace_id == workspace_id then
            fallback = fallback or p
            if p.focused then
                return p
            end
        end
    end
    return fallback
end

local function item_pane(item)
    if not item then
        return nil
    end
    return item.kind == "pane" and item.pane or first_pane_of_space(item.workspace_id)
end

-- snacks.nvim picker ----------------------------------------------------------

local style ---@type table resolved once per picker

local function format(item, picker)
    local ret = Snacks.picker.format.tree(item, picker)
    local st = state.status(item.status)
    if item.kind == "space" then
        ret[#ret + 1] = { style.icons.space_open, "SnacksPickerDirectory" }
        ret[#ret + 1] = { item.name, "SnacksPickerDirectory" }
    else
        ret[#ret + 1] = {
            item.agent and style.icons.agent or style.icons.shell,
            item.agent and "HerdrAgentIcon" or "HerdrShellIcon",
        }
        ret[#ret + 1] = { item.name, item.focused and "HerdrFocusedName" or "SnacksPickerFile" }
        if item.agent then
            ret[#ret + 1] = { "  " .. item.agent, "SnacksPickerComment" }
        end
    end
    if item.status and item.status ~= "unknown" then
        ret[#ret + 1] = { "  " .. st.icon .. " " .. item.status, st.hl }
    end
    return ret
end

local function preview_space(ctx)
    local item = ctx.item
    local lines = { item.name, "" }
    local hls = {}
    for _, p in ipairs(state.snapshot and state.snapshot.panes or {}) do
        if p.workspace_id == item.workspace_id then
            local st = state.status(state.pane_status(p))
            local agent = p.display_agent or p.agent
            lines[#lines + 1] =
                string.format("  %s %s%s", st.icon, state.pane_label(p), agent and ("  (" .. agent .. ")") or "")
            hls[#hls + 1] = { #lines - 1, 2, 2 + #st.icon, st.hl }
            if p.foreground_cwd or p.cwd then
                lines[#lines + 1] = "      " .. (p.foreground_cwd or p.cwd)
                hls[#hls + 1] = { #lines - 1, 0, #lines[#lines], "Comment" }
            end
        end
    end
    ctx.preview:reset()
    ctx.preview:minimal()
    ctx.preview:set_title(item.name)
    ctx.preview:set_lines(lines)
    local buf = ctx.buf or ctx.preview.win.buf
    local pns = vim.api.nvim_create_namespace("herdr_picker_preview")
    vim.api.nvim_buf_set_extmark(buf, pns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
    for _, h in ipairs(hls) do
        pcall(vim.api.nvim_buf_set_extmark, buf, pns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
end

local function preview_pane(ctx)
    local item = ctx.item
    local buf = ctx.preview:scratch()
    ctx.preview:set_title(item.name .. (item.agent and ("  " .. item.agent) or ""))
    local chan = vim.api.nvim_open_term(buf, {})
    local params = { pane_id = item.pane.pane_id, source = "visible", format = "ansi", strip_ansi = false }
    api.request("pane.read", params, function(err, res)
        if not vim.api.nvim_buf_is_valid(buf) then
            return -- the selection moved on
        end
        local text = err and ("herdr: " .. err) or (res and res.read and res.read.text or "")
        -- Terminal buffers need CRLF line endings.
        text = text:gsub("\r\n", "\n"):gsub("\n", "\r\n")
        pcall(vim.api.nvim_chan_send, chan, text)
    end)
end

local function open_snacks(opts)
    local style_mod = require("herdr.style")
    style_mod.define_highlights()
    style = style_mod.get()
    local off
    local picker = Snacks.picker.pick({
        source = "herdr",
        title = state.snapshot and "Herdr" or "Herdr  connecting…",
        -- Keep the picker open while the first snapshot is still loading.
        show_empty = true,
        finder = function()
            return M.items()
        end,
        format = format,
        preview = function(ctx)
            if ctx.item.kind == "pane" then
                preview_pane(ctx)
            else
                preview_space(ctx)
            end
        end,
        sort = { fields = { "score:desc", "idx" } },
        matcher = { sort_empty = false },
        confirm = function(p, item)
            -- Several items marked with <Tab>: open them all, tiled.
            local selected = p:selected()
            if #selected > 1 then
                local panes, seen = {}, {}
                for _, it in ipairs(selected) do
                    local list = it.kind == "pane" and { it.pane } or {}
                    if it.kind == "space" then
                        for _, sp in ipairs(state.snapshot and state.snapshot.panes or {}) do
                            if sp.workspace_id == it.workspace_id then
                                list[#list + 1] = sp
                            end
                        end
                    end
                    for _, pn in ipairs(list) do
                        if not seen[pn.pane_id] then
                            seen[pn.pane_id] = true
                            panes[#panes + 1] = pn
                        end
                    end
                end
                p:close()
                return vim.schedule(function()
                    terminal.open_many(panes)
                end)
            end
            local pane = item_pane(item)
            p:close()
            if pane then
                vim.schedule(function()
                    terminal.open(pane, vim.tbl_extend("force", { how = "current" }, opts or {}))
                end)
            end
        end,
        actions = {
            herdr_vsplit = function(p, item)
                local pane = item_pane(item)
                p:close()
                if pane then
                    vim.schedule(function()
                        terminal.open(pane, { how = "vsplit" })
                    end)
                end
            end,
            herdr_split = function(p, item)
                local pane = item_pane(item)
                p:close()
                if pane then
                    vim.schedule(function()
                        terminal.open(pane, { how = "split" })
                    end)
                end
            end,
            herdr_tab = function(p, item)
                local pane = item_pane(item)
                p:close()
                if pane then
                    vim.schedule(function()
                        terminal.open(pane, { how = "tab" })
                    end)
                end
            end,
            herdr_focus = function(_, item)
                if not item then
                    return
                end
                local method, params
                if item.kind == "space" then
                    method, params = "workspace.focus", { workspace_id = item.workspace_id }
                else
                    method, params = "pane.focus", { pane_id = item.pane.pane_id }
                end
                api.request(method, params, function(err)
                    if err then
                        vim.notify("herdr: " .. method .. " failed: " .. err, vim.log.levels.ERROR)
                    end
                    state.refresh()
                end)
            end,
        },
        win = {
            input = {
                keys = {
                    ["<c-v>"] = { "herdr_vsplit", mode = { "n", "i" }, desc = "Open in vsplit" },
                    ["<c-s>"] = { "herdr_split", mode = { "n", "i" }, desc = "Open in split" },
                    ["<c-t>"] = { "herdr_tab", mode = { "n", "i" }, desc = "Open in tab" },
                    ["<a-f>"] = { "herdr_focus", mode = { "n", "i" }, desc = "Focus in herdr" },
                },
            },
        },
        on_close = function()
            if off then
                off()
            end
        end,
    })
    -- Live: re-run the finder whenever the session changes (keeps the query).
    off = state.on_change(function()
        vim.schedule(function()
            if picker and not picker.closed then
                if picker.title ~= "Herdr" and state.snapshot then
                    picker.title = "Herdr"
                    picker:update_titles()
                end
                picker:find()
            end
        end)
    end)
    state.start()
end

-- Fallback ------------------------------------------------------------------

local function open_select(opts)
    local function pick()
        local entries = {}
        for _, item in ipairs(M.items()) do
            if item.kind == "pane" then
                entries[#entries + 1] = item
            end
        end
        vim.ui.select(entries, {
            prompt = "herdr",
            format_item = function(item)
                return string.format(
                    "%s %s / %s%s",
                    state.status_icon(item.status),
                    item.parent.name,
                    item.name,
                    item.agent and ("  " .. item.agent) or ""
                )
            end,
        }, function(choice)
            if choice then
                terminal.open(choice.pane, opts)
            end
        end)
    end
    if state.snapshot then
        return pick()
    end
    local off
    off = state.on_change(function(snap, err)
        if snap then
            off()
            vim.schedule(pick)
        elseif err then
            off()
            vim.notify("herdr: " .. err, vim.log.levels.ERROR)
        end
    end)
    state.start()
end

function M.open(opts)
    if not require("herdr.connection").active then
        return require("herdr.connection").with_connection(function()
            M.open(opts)
        end)
    end
    local ok = package.loaded["snacks"] and type(Snacks) == "table" and Snacks.picker and Snacks.picker.pick
    if ok then
        return open_snacks(opts)
    end
    open_select(opts)
end

return M
