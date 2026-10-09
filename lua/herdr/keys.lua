-- Configurable buffer-local keys.
--
-- A key table maps lhs -> action name, `false` (disable a default), or
-- { "action", mode = "n" | { ... } } to choose the modes. Actions are
-- { fn = function|string, mode = default mode(s), desc = string } or plain functions.

local M = {}

local function resolve(spec)
    if type(spec) == "table" then
        return spec[1], spec.mode
    end
    return spec, nil
end

--- Map `keys` on `buf` to `actions`.
---@param buf integer
---@param keys table<string, string|table|false>|false|nil
---@param actions table<string, table|function>
function M.apply(buf, keys, actions)
    for lhs, spec in pairs(keys or {}) do
        if spec then
            local name, mode = resolve(spec)
            local action = actions[name]
            if action then
                local fn = type(action) == "function" and action or action.fn
                mode = mode or (type(action) == "table" and action.mode) or "n"
                local desc = type(action) == "table" and action.desc or tostring(name)
                vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
            else
                vim.notify(("herdr: unknown action %q for key %s"):format(tostring(name), lhs), vim.log.levels.WARN)
            end
        end
    end
end

--- Keys bound to each action, for help text: { action = { lhs, ... } }.
function M.by_action(keys)
    local out = {}
    for lhs, spec in pairs(keys or {}) do
        if spec then
            local name = resolve(spec)
            out[name] = out[name] or {}
            table.insert(out[name], lhs)
        end
    end
    for _, list in pairs(out) do
        table.sort(list)
    end
    return out
end

return M
