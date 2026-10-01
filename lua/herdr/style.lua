-- Visual style for the herdr tree, borrowed from the user's file explorer so
-- the tree looks like it belongs in their setup.
--
-- Resolution order: explicit `tree` options > snacks.nvim explorer >
-- neo-tree > built-in defaults (which match snacks' explorer).

local config = require("herdr.config")

local M = {}

local DEFAULTS = {
    source = "default",
    position = "left",
    width = 40,
    indent = { vertical = "│ ", middle = "├╴", last = "└╴", blank = "  " },
    icons = {
        root = "󰒋 ",
        space_closed = "󰉋 ",
        space_open = "󰝰 ",
        group_closed = "󰓩 ", -- a herdr tab holding split panes
        group_open = "󰓩 ",
        agent = "󰚩 ",
        shell = "󰆍 ", -- a plain terminal: no agent detected
        attached = "↗",
    },
    hl = {
        indent = "LineNr",
        space = "Directory",
        group = "Directory",
    },
}

local function pad(s)
    if not s or s == "" then
        return s
    end
    return vim.fn.strdisplaywidth(s) < 2 and (s .. " ") or s
end

local function from_snacks()
    if not package.loaded["snacks"] then
        return nil
    end
    local ok, picker_config = pcall(require, "snacks.picker.config")
    if not ok then
        return nil
    end
    local ok2, opts = pcall(picker_config.get, { source = "explorer" })
    if not ok2 or type(opts) ~= "table" then
        return nil
    end
    local s = { source = "snacks", icons = {}, indent = {}, hl = {} }
    local icons = opts.icons or {}
    if icons.tree then
        s.indent.vertical = icons.tree.vertical
        s.indent.middle = icons.tree.middle
        s.indent.last = icons.tree.last
    end
    if icons.files then
        s.icons.space_closed = icons.files.dir
        s.icons.space_open = icons.files.dir_open
    end
    local layout = opts.layout
    if type(layout) == "table" and layout.preset then
        local ok3, layouts = pcall(require, "snacks.picker.config.layouts")
        local preset = ok3 and layouts[layout.preset]
        layout = vim.tbl_deep_extend("force", preset or {}, layout)
    end
    local l = type(layout) == "table" and layout.layout or nil
    if l then
        s.width = type(l.width) == "number" and l.width >= 1 and l.width or nil
        s.position = (l.position == "left" or l.position == "right") and l.position or nil
    end
    s.hl.indent = "SnacksPickerTree"
    s.hl.space = "SnacksPickerDirectory"
    s.hl.group = "SnacksPickerDirectory"
    return s
end

local function from_neotree()
    if not package.loaded["neo-tree"] then
        return nil
    end
    local ok, neotree = pcall(require, "neo-tree")
    local c = ok and neotree.config
    if type(c) ~= "table" then
        return nil
    end
    local comp = c.default_component_configs or {}
    local indent, icon = comp.indent or {}, comp.icon or {}
    local win = c.window or {}
    local s = { source = "neo-tree", icons = {}, indent = {}, hl = {} }
    if indent.with_markers ~= false then
        s.indent.vertical = pad(indent.indent_marker)
        s.indent.middle = pad(indent.indent_marker and "├")
        s.indent.last = pad(indent.last_indent_marker)
    end
    s.icons.space_closed = pad(icon.folder_closed)
    s.icons.space_open = pad(icon.folder_open)
    s.width = type(win.width) == "number" and win.width or nil
    s.position = (win.position == "left" or win.position == "right") and win.position or nil
    s.hl.indent = "NeoTreeIndentMarker"
    s.hl.space = "NeoTreeDirectoryName"
    s.hl.group = "NeoTreeDirectoryName"
    return s
end

local function drop_nils(t)
    for k, v in pairs(t) do
        if type(v) == "table" then
            drop_nils(v)
        end
        if v == "" then
            t[k] = nil
        end
    end
    return t
end

function M.define_highlights()
    local set = function(name, link)
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
    -- Herdr's colors: yellow working, red blocked, teal done, green idle.
    set("HerdrWorking", "DiagnosticWarn")
    set("HerdrBlocked", "DiagnosticError")
    set("HerdrDone", "DiagnosticHint")
    set("HerdrIdle", "DiagnosticOk")
    set("HerdrUnknown", "NonText")
    set("HerdrRoot", "Title")
    set("HerdrName", "Normal")
    set("HerdrAgentIcon", "Special")
    set("HerdrShellIcon", "Comment")
    set("HerdrMuted", "Comment")
    set("HerdrAttached", "Special")
    vim.api.nvim_set_hl(0, "HerdrFocused", { bold = true, default = true })
    -- A single-highlight variant for places that cannot layer (picker items).
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    vim.api.nvim_set_hl(0, "HerdrFocusedName", { fg = normal.fg, bold = true, default = true })
    set("HerdrError", "DiagnosticError")
end

--- Resolve the effective style (cheap; call when opening the tree).
function M.get()
    local detected = from_snacks() or from_neotree() or {}
    local s = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), drop_nils(detected))
    local user = config.options.tree or {}
    s = vim.tbl_deep_extend("force", s, {
        width = user.width,
        position = user.position,
        icons = user.icons,
        indent = user.indent,
    })
    -- Fall back if a borrowed highlight group does not exist in this session.
    for k, group in pairs(s.hl) do
        if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = group })) then
            s.hl[k] = DEFAULTS.hl[k]
        end
    end
    s.indent.blank = string.rep(" ", vim.fn.strdisplaywidth(s.indent.vertical))
    return s
end

return M
