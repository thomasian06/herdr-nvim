-- Client for Herdr's JSON socket API.
--
-- Wire format: one JSON object per line, {"id", "method", "params"}.
-- The server answers a single request per connection, except
-- `events.subscribe`, which keeps streaming one event per line.

local transport = require("herdr.transport")

local M = {}

local next_id = 0
local function new_id()
    next_id = next_id + 1
    return "nvim-" .. next_id
end

local function encode(method, params)
    return vim.json.encode({
        id = new_id(),
        method = method,
        params = (params and next(params)) and params or vim.empty_dict(),
    }) .. "\n"
end

local function decode(line)
    local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok then
        return nil, "invalid JSON from herdr: " .. tostring(msg)
    end
    return msg
end

local function response_error(msg)
    if msg.error then
        return (msg.error.code and (msg.error.code .. ": ") or "") .. (msg.error.message or vim.inspect(msg.error))
    end
end

-- Open a connection, send one request, and deliver each response line to on_line.
-- on_line returns true to keep reading. on_close(err) runs once.
local function connect(method, params, on_line, on_close)
    local closed = false
    local pipe = assert(vim.uv.new_pipe(false))
    local function close(err)
        if closed then
            return
        end
        closed = true
        if not pipe:is_closing() then
            pipe:close()
        end
        vim.schedule(function()
            on_close(err)
        end)
    end

    transport.ensure(function(err)
        if err then
            return close(err)
        end
        pipe:connect(transport.api_socket, function(cerr)
            if cerr then
                -- The socket is gone (server restarted, SSH forward dropped):
                -- the connection is lost; transport reconnects with backoff.
                vim.schedule(function()
                    transport.lost("herdr API socket unreachable (" .. cerr .. ")")
                end)
                return close("connect to herdr API socket failed: " .. cerr)
            end
            pipe:write(encode(method, params))
            local buf = ""
            pipe:read_start(function(rerr, chunk)
                if rerr then
                    return close(rerr)
                end
                if not chunk then
                    return close(nil)
                end
                buf = buf .. chunk
                while true do
                    local nl = buf:find("\n", 1, true)
                    if not nl then
                        break
                    end
                    local line = buf:sub(1, nl - 1)
                    buf = buf:sub(nl + 1)
                    if line ~= "" then
                        local msg, derr = decode(line)
                        local keep = false
                        if msg then
                            keep = on_line(msg)
                        else
                            close(derr)
                        end
                        if not keep then
                            return close(nil)
                        end
                    end
                end
            end)
        end)
    end)

    return {
        close = function()
            close(nil)
        end,
    }
end

--- Send one request. cb(err, result) runs on the main loop.
---@param method string
---@param params table?
---@param cb fun(err: string?, result: table?)
function M.request(method, params, cb)
    local result, err
    connect(method, params, function(msg)
        err = response_error(msg)
        result = msg.result
        return false
    end, function(cerr)
        cb = cb or function() end
        if cerr then
            return cb(cerr, nil)
        end
        if not result and not err then
            err = "herdr closed the connection without a response"
        end
        cb(err, result)
    end)
end

--- Subscribe to server events. on_event(event, data) runs on the main loop.
--- on_close(err) runs when the stream ends. Returns a handle with :close().
---@param subscriptions table[]
---@param on_event fun(event: string, data: table)
---@param on_close fun(err: string?)
function M.subscribe(subscriptions, on_event, on_close)
    local started = false
    local sub_err
    return connect("events.subscribe", { subscriptions = subscriptions }, function(msg)
        sub_err = response_error(msg)
        if sub_err then
            return false
        end
        if not started then
            started = msg.result and msg.result.type == "subscription_started"
            return true
        end
        local ev = msg.result or msg
        vim.schedule(function()
            on_event(ev.event, ev.data)
        end)
        return true
    end, function(err)
        on_close(err or sub_err)
    end)
end

return M
