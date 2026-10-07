-- The herdr tree: a file-explorer-style view of the session.
--
--   󰒋 devbox:main                  (root: `a` here adds a space)
--   ├╴󰝰 api-server                ○  (space = folder)
--   │ ├╴󰚩 api-server  claude      ○  (terminal/agent = file)
--   │ └╴ dev server
--   └╴󰝰 website                   ●
--
-- Herdr tabs are flattened: a tab with one pane shows as that pane, and only a
-- tab with split panes becomes a nested group.

local api = require("herdr.api")
local state = require("herdr.state")
local style_mod = require("herdr.style")
local terminal = require("herdr.terminal")

local M = {}

local ns = vim.api.nvim_create_namespace("herdr_tree")
local buf ---@type integer?
local style ---@type table
local line_nodes = {} ---@type table<integer, table> 1-based line -> node
local node_lines = {} ---@type table<string, integer> node key -> line
local collapsed = {} ---@type table<string, boolean> node key -> collapsed
local pending_cursor_key ---@type string? move the cursor here once it appears

-- Model ---------------------------------------------------------------------

local function is_default_tab_label(label)
    return not label or label == "" or label:match("^%d+$") ~= nil
end

local function pane_node(p, tab, ws, name)
    return {
        key = "pane:" .. p.pane_id,
        kind = "pane",
        id = p.pane_id,
        pane = p,
        workspace_id = p.workspace_id,
        tab_id = p.tab_id,
        name = name,
        detail = p.display_agent or p.agent,
        status = state.pane_status(p),
        focused = p.focused and tab.focused and ws.focused,
    }
end

local function build()
    local s = state.snapshot
    local root = { key = "root", kind = "root", children = {} }
    if not s then
        return root
    end
    for _, ws in ipairs(s.workspaces or {}) do
        local space = {
            key = "ws:" .. ws.workspace_id,
            kind = "space",
            id = ws.workspace_id,
            workspace_id = ws.workspace_id,
            name = ws.label or ws.workspace_id,
            status = state.workspace_status(ws.workspace_id),
            focused = ws.focused,
            children = {},
            parent = root,
        }
        root.children[#root.children + 1] = space
        for _, tab in ipairs(s.tabs or {}) do
            if tab.workspace_id == ws.workspace_id then
                local panes = state.tab_panes(tab.tab_id)
                local custom = not is_default_tab_label(tab.label)
                if #panes == 1 then
                    local n = pane_node(panes[1], tab, ws, custom and tab.label or state.pane_label(panes[1]))
                    n.parent = space
                    space.children[#space.children + 1] = n
                elseif #panes > 1 then
                    local group = {
                        key = "tab:" .. tab.tab_id,
                        kind = "group",
                        id = tab.tab_id,
                        workspace_id = ws.workspace_id,
                        tab_id = tab.tab_id,
                        name = custom and tab.label or ("tab " .. (tab.number or tab.label or "")),
                        status = state.tab_status(tab.tab_id),
                        focused = tab.focused and ws.focused,
                        children = {},
                        parent = space,
                    }
                    space.children[#space.children + 1] = group
                    for _, p in ipairs(panes) do
                        local n = pane_node(p, tab, ws, state.pane_label(p))
                        n.parent = group
                        group.children[#group.children + 1] = n
                    end
                end
            end
        end
    end
    return root
end

-- Rendering -----------------------------------------------------------------

local function win()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return nil
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == buf then
            return w
        end
    end
end

local function current_node()
    local w = win()
    return w and line_nodes[vim.api.nvim_win_get_cursor(w)[1]] or nil
end

local function render()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    local w = win()
    local cursor_key = pending_cursor_key
    if not cursor_key and w then
        local n = line_nodes[vim.api.nvim_win_get_cursor(w)[1]]
        cursor_key = n and n.key
    end

    local lines, marks, virt = {}, {}, {}
    line_nodes, node_lines = {}, {}
    local attached = terminal.attached_panes()

    local function add(text, node, hls, right)
        lines[#lines + 1] = text
        if node then
            line_nodes[#lines] = node
            node_lines[node.key] = #lines
        end
        for _, h in pairs(hls or {}) do
            if h[2] > h[1] then
                marks[#marks + 1] = { #lines - 1, h[1], h[2], h[3] }
            end
        end
        if right and #right > 0 then
            virt[#virt + 1] = { #lines - 1, right }
        end
    end

    local root = build()
    local connection = require("herdr.connection")
    local root_text = style.icons.root .. connection.label(connection.current())
    add(root_text, root, { { 0, #root_text, "HerdrRoot" } })

    if state.error then
        for _, l in ipairs(vim.split(state.error, "\n")) do
            add("  " .. l, nil, { { 0, #l + 2, "HerdrError" } })
        end
    end
    if not connection.active then
        local hint = "  press C to connect (:Herdr connect)"
        add("", nil)
        add(hint, nil, { { 0, #hint, "HerdrMuted" } })
    elseif not state.snapshot and not state.error then
        add("  connecting…", nil, { { 0, 15, "HerdrMuted" } })
    end

    local function walk(node, guides)
        for i, child in ipairs(node.children or {}) do
            local last = i == #node.children
            local prefix = guides .. (last and style.indent.last or style.indent.middle)
            local open = child.children and not collapsed[child.key]
            local icon, icon_hl, name_hl
            if child.kind == "space" then
                icon = open and style.icons.space_open or style.icons.space_closed
                icon_hl, name_hl = style.hl.space, style.hl.space
            elseif child.kind == "group" then
                icon = open and style.icons.group_open or style.icons.group_closed
                icon_hl, name_hl = style.hl.group, style.hl.group
            else
                icon = child.detail and style.icons.agent or style.icons.shell
                icon_hl, name_hl = child.detail and "HerdrAgentIcon" or "HerdrShellIcon", "HerdrName"
            end
            if attached[child.id] then
                name_hl = "HerdrAttached"
            end
            local detail = child.detail and ("  " .. child.detail) or ""
            local text = prefix .. icon .. child.name .. detail
            local c1, c2 = #prefix, #prefix + #icon
            local c3 = c2 + #child.name
            local right = {}
            if attached[child.id] then
                right[#right + 1] = { style.icons.attached .. " ", "HerdrAttached" }
            end
            local st = state.status(child.status)
            if child.status then
                right[#right + 1] = { st.icon .. " ", st.hl }
            end
            add(text, child, {
                { 0, c1, style.hl.indent },
                { c1, c2, icon_hl },
                { c2, c3, name_hl },
                { c3, #text, "HerdrMuted" },
                child.focused and { c2, c3, "HerdrFocused" } or nil,
            }, right)
            if open then
                walk(child, guides .. (last and style.indent.blank or style.indent.vertical))
            end
        end
    end
    walk(root, "")

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(marks) do
        -- HerdrFocused (bold) layers on top of the name's own color.
        local priority = m[4] == "HerdrFocused" and 200 or 100
        vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4], priority = priority })
    end
    for _, v in ipairs(virt) do
        vim.api.nvim_buf_set_extmark(buf, ns, v[1], 0, { virt_text = v[2], virt_text_pos = "right_align" })
    end

    if w and cursor_key and node_lines[cursor_key] then
        vim.api.nvim_win_set_cursor(w, { node_lines[cursor_key], 0 })
        if cursor_key == pending_cursor_key then
            pending_cursor_key = nil
        end
    end
end

-- Actions -------------------------------------------------------------------

local function done(what, after)
    return function(err, result)
        if err then
            vim.notify("herdr: " .. what .. " failed: " .. err, vim.log.levels.ERROR)
        elseif after then
            after(result)
        end
        state.refresh()
    end
end

local function first_pane(node)
    if node.kind == "pane" then
        return node.pane
    end
    local fallback
    local function find(n)
        for _, c in ipairs(n.children or {}) do
            if c.kind == "pane" then
                fallback = fallback or c.pane
                if c.pane.focused then
                    return c.pane
                end
            else
                local p = find(c)
                if p then
                    return p
                end
            end
        end
    end
    return find(node) or fallback
end

local function toggle(node)
    if node.children then
        collapsed[node.key] = not collapsed[node.key] or nil
        render()
    end
end

local actions = {}

--- Open a terminal, or toggle a folder when no explicit target is given.
function actions.open(how, takeover)
    return function()
        local node = current_node()
        if not node or node.kind == "root" then
            return
        end
        if node.children and not how then
            return toggle(node)
        end
        local pane = first_pane(node)
        if pane then
            terminal.open(pane, { how = how or "current", takeover = takeover })
        end
    end
end

--- `O`: open every terminal under the node, tiled in a new tab. On the root:
--- every agent in the session.
function actions.open_all()
    local node = current_node()
    if not node then
        return
    end
    local panes = {}
    if node.kind == "root" then
        for _, p in ipairs(state.snapshot and state.snapshot.panes or {}) do
            if p.agent then
                panes[#panes + 1] = p
            end
        end
    else
        local function collect(n)
            if n.kind == "pane" then
                panes[#panes + 1] = n.pane
            end
            for _, c in ipairs(n.children or {}) do
                collect(c)
            end
        end
        collect(node)
    end
    terminal.open_many(panes)
end

function actions.expand()
    local node = current_node()
    if not node or node.kind == "root" then
        return
    end
    if node.kind == "pane" then
        return actions.open()()
    end
    if collapsed[node.key] then
        return toggle(node)
    end
    local child = node.children[1]
    local w = win()
    if w and child and node_lines[child.key] then
        vim.api.nvim_win_set_cursor(w, { node_lines[child.key], 0 })
    end
end

function actions.collapse()
    local node = current_node()
    if not node or node.kind == "root" then
        return
    end
    if node.children and not collapsed[node.key] then
        return toggle(node)
    end
    local parent = node.parent
    local w = win()
    if w and parent and node_lines[parent.key] then
        vim.api.nvim_win_set_cursor(w, { node_lines[parent.key], 0 })
    end
end

function actions.collapse_all()
    for _, n in pairs(line_nodes) do
        if n.kind == "space" or n.kind == "group" then
            collapsed[n.key] = true
        end
    end
    render()
end

local function open_created(result)
    local pane = result and result.root_pane
    if not pane then
        return
    end
    collapsed["ws:" .. pane.workspace_id] = nil
    pending_cursor_key = "pane:" .. pane.pane_id
    terminal.open(pane, { how = "current" })
end

--- Create a space (asking for a name unless given) and open its terminal.
--- Asks for a connection first when disconnected.
---@param name string?
function actions.add_space(name)
    local connection = require("herdr.connection")
    if not connection.active then
        return connection.with_connection(function()
            actions.add_space(name)
        end)
    end
    local function create(label)
        local params = { focus = false }
        if label and vim.trim(label) ~= "" then
            params.label = vim.trim(label)
        end
        -- Start in the connection's projects folder when one is configured.
        require("herdr.transport").resolve_path(connection.projects_dir(), function(cwd)
            params.cwd = cwd
            api.request("workspace.create", params, done("workspace.create", open_created))
        end)
    end
    if type(name) == "string" then
        return create(name)
    end
    require("herdr.ui").input({ prompt = "New space name (empty for default): " }, function(input)
        if input ~= nil then
            create(input)
        end
    end)
end

--- `a`: new terminal in the space under the cursor, or a new space on the root.
function actions.add()
    if not require("herdr.connection").active then
        return require("herdr.connection").pick()
    end
    local node = current_node()
    if not node or node.kind == "root" then
        return actions.add_space()
    end
    local ws = state.workspace(node.workspace_id)
    local ws_name = ws and ws.label or node.workspace_id
    require("herdr.ui").input({ prompt = "New terminal in " .. ws_name .. " (name, optional): " }, function(name)
        if name == nil then
            return
        end
        local params = { workspace_id = node.workspace_id, focus = false }
        if vim.trim(name) ~= "" then
            params.label = vim.trim(name)
        end
        api.request("tab.create", params, done("tab.create", open_created))
    end)
end

-- What a node maps to in herdr for rename/close/focus: a pane that is alone in
-- its tab is presented as the tab, so act on the tab.
local function target(node)
    if node.kind == "space" then
        return "workspace", node.id
    elseif node.kind == "group" then
        return "tab", node.id
    elseif node.kind == "pane" then
        local parent = node.parent
        if parent and parent.kind == "group" then
            return "pane", node.id
        end
        return "tab", node.tab_id
    end
end

function actions.rename()
    local node = current_node()
    local kind, id = target(node or {})
    if not (node and kind) then
        return
    end
    require("herdr.ui").input({ prompt = "Rename: ", default = node.name }, function(name)
        if name == nil or vim.trim(name) == "" then
            return
        end
        local method = kind .. ".rename"
        api.request(method, { [kind .. "_id"] = id, label = vim.trim(name) }, done(method))
    end)
end

function actions.delete()
    local node = current_node()
    local kind, id = target(node or {})
    if not (node and kind) then
        return
    end
    local what = node.kind == "space" and ("space '" .. node.name .. "' and all its terminals")
        or ("'" .. node.name .. "'")
    if vim.fn.confirm("Close " .. what .. " in herdr?", "&Yes\n&No", 2) ~= 1 then
        return
    end
    local method = kind .. ".close"
    api.request(method, { [kind .. "_id"] = id }, done(method))
end

--- Move the space or terminal under the cursor up (-1) or down (+1) among its
--- siblings, in Herdr's order. Split panes follow Herdr's layout, so a pane in
--- a group moves with its tab (the group's row).
function actions.move(delta)
    local node = current_node()
    if not node or node.kind == "root" then
        return
    end
    local s = state.snapshot or {}
    local kind, id = target(node)
    local siblings = {}
    if kind == "workspace" then
        for _, ws in ipairs(s.workspaces or {}) do
            siblings[#siblings + 1] = ws.workspace_id
        end
    elseif kind == "tab" then
        for _, tab in ipairs(s.tabs or {}) do
            if tab.workspace_id == node.workspace_id then
                siblings[#siblings + 1] = tab.tab_id
            end
        end
    else
        return vim.notify("herdr: split panes follow Herdr's layout; move their tab instead", vim.log.levels.INFO)
    end
    local i = vim.tbl_contains(siblings, id) and vim.fn.index(siblings, id) + 1 or nil
    local j = i and i + delta
    if not j or j < 1 or j > #siblings then
        return
    end
    -- Herdr's insert_index is a 0-based position in the list before the move.
    local insert_index = delta < 0 and j - 1 or j
    -- Swap with the neighbour in the local snapshot right away, so the tree
    -- updates at once and a quick second press starts from the new order;
    -- the refresh after the request confirms it.
    local list, field = s.workspaces, "workspace_id"
    if kind == "tab" then
        list, field = s.tabs, "tab_id"
    end
    local a, b
    for k, item in ipairs(list or {}) do
        if item[field] == id then
            a = k
        elseif item[field] == siblings[j] then
            b = k
        end
    end
    if a and b then
        list[a], list[b] = list[b], list[a]
    end
    pending_cursor_key = node.key
    render()
    local method = kind .. ".move"
    api.request(method, { [kind .. "_id"] = id, insert_index = insert_index }, done(method))
end

function actions.focus_in_herdr()
    local node = current_node()
    if not node or node.kind == "root" then
        return
    end
    local kind = ({ space = "workspace", group = "tab", pane = "pane" })[node.kind]
    local method = kind .. ".focus"
    api.request(method, { [kind .. "_id"] = node.id }, done(method))
end

-- Tree actions for `tree.keys`, in help order: name -> { description, fn }.
local ACTIONS = {
    { "open", "open terminal / toggle space", actions.open() },
    { "expand", "expand (or open a terminal)", actions.expand },
    { "collapse", "collapse (or go to parent)", actions.collapse },
    { "vsplit", "open in vertical split", actions.open("vsplit") },
    { "split", "open in horizontal split", actions.open("split") },
    { "tab", "open in new tab", actions.open("tab") },
    { "takeover", "open, taking over another attach", actions.open("current", true) },
    { "open_all", "open all terminals here, tiled (root: all agents)", actions.open_all },
    { "add", "add terminal to space (on root: add space)", actions.add },
    {
        "add_space",
        "add space",
        function()
            actions.add_space()
        end,
    },
    { "rename", "rename", actions.rename },
    { "delete", "close in herdr", actions.delete },
    {
        "move_up",
        "move space/terminal up",
        function()
            actions.move(-1)
        end,
    },
    {
        "move_down",
        "move space/terminal down",
        function()
            actions.move(1)
        end,
    },
    { "focus", "focus in herdr's own UI", actions.focus_in_herdr },
    {
        "connect",
        "connect to another server/profile",
        function()
            require("herdr.connection").pick()
        end,
    },
    -- Non-remapping RHS strings preserve native counts and bypass global `zz` mappings.
    { "scroll_down", "scroll down half a page", "<C-d>" },
    { "scroll_up", "scroll up half a page", "<C-u>" },
    { "collapse_all", "collapse all", actions.collapse_all },
    {
        "refresh",
        "refresh",
        function()
            state.refresh()
        end,
    },
    {
        "close",
        "close tree",
        function()
            M.close()
        end,
    },
    {
        "help",
        "help",
        function()
            actions.help()
        end,
    },
}

function actions.help()
    local by = require("herdr.keys").by_action(require("herdr.config").options.tree.keys)
    local lines = { " herdr tree", "" }
    for _, a in ipairs(ACTIONS) do
        if by[a[1]] and a[1] ~= "help" then
            lines[#lines + 1] = string.format("  %-14s %s", table.concat(by[a[1]], " "), a[2])
        end
    end
    local hbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
    vim.bo[hbuf].modifiable = false
    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
    end
    local hwin = vim.api.nvim_open_win(hbuf, true, {
        relative = "editor",
        width = width,
        height = #lines,
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " help ",
        title_pos = "center",
    })
    vim.api.nvim_buf_set_extmark(hbuf, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
    local close_keys = { "q", "<Esc>" }
    vim.list_extend(close_keys, by.help or {})
    for _, key in ipairs(close_keys) do
        vim.keymap.set("n", key, function()
            pcall(vim.api.nvim_win_close, hwin, true)
        end, { buffer = hbuf, nowait = true })
    end
end

-- Window ----------------------------------------------------------------------

local function setup_buffer()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "herdr://tree")
    vim.bo[buf].filetype = "herdr"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].modifiable = false
    local tree_actions = {}
    for _, a in ipairs(ACTIONS) do
        tree_actions[a[1]] = { desc = "herdr: " .. a[2], fn = a[3] }
    end
    require("herdr.keys").apply(buf, require("herdr.config").options.tree.keys, tree_actions)
end

function M.open()
    style_mod.define_highlights()
    style = style_mod.get()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        setup_buffer()
    end
    local w = win()
    if not w then
        vim.cmd((style.position == "right" and "botright" or "topleft") .. " vertical " .. style.width .. "split")
        w = vim.api.nvim_get_current_win()
        assert(buf, "herdr: tree buffer missing")
        vim.api.nvim_win_set_buf(w, buf)
        local wo = vim.wo[w]
        wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
        wo.foldcolumn, wo.spell, wo.list, wo.wrap = "0", false, false, false
        wo.winfixwidth, wo.cursorline = true, true
        wo.scrolloff = require("herdr.config").options.tree.scrolloff
        wo.statuscolumn = ""
    end
    vim.api.nvim_set_current_win(w)
    state.start()
    render()
end

function M.close()
    local w = win()
    if w and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(w, true)
    end
end

function M.toggle()
    if win() then
        M.close()
    else
        M.open()
    end
end

M.render = render
M.add_space = actions.add_space

state.on_change(function()
    vim.schedule(render)
end)

local group = vim.api.nvim_create_augroup("herdr_tree", { clear = true })
vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "HerdrAttach", "HerdrDetach" },
    callback = function()
        vim.schedule(render)
    end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = "herdr://*",
    callback = function()
        vim.schedule(render)
    end,
})

return M
