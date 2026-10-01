-- Read a few settings from Herdr's own config (~/.config/herdr/config.toml), so
-- herdr-nvim follows them: [ui] status_indicators and [ui.sound]. Only flat
-- `key = value` pairs are needed, so this is a minimal reader, not a TOML parser.

local M = {}

local function path()
    local dir = (vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "") and vim.env.XDG_CONFIG_HOME
        or (vim.env.HOME .. "/.config")
    return dir .. "/herdr/config.toml"
end

--- Key/value pairs of one [section] (strings unquoted, booleans converted).
--- Relative file paths are resolved against the config directory when
--- `resolve_paths` is set.
function M.section(name, resolve_paths)
    local file = path()
    local out = {}
    local f = io.open(file, "r")
    if not f then
        return out
    end
    local current
    for line in f:lines() do
        line = line:gsub("%s+#.*$", "")
        local s = line:match("^%s*%[([^%]]+)%]%s*$")
        if s then
            current = s
        elseif current == name then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then
                v = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
                if v == "true" or v == "false" then
                    v = v == "true"
                elseif resolve_paths and type(v) == "string" and v:sub(1, 1) ~= "/" and v:sub(1, 1) ~= "~" then
                    v = vim.fn.fnamemodify(file, ":h") .. "/" .. v
                end
                out[k] = v
            end
        end
    end
    f:close()
    return out
end

return M
