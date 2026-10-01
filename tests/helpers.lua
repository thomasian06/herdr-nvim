local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

--- A child Neovim started with the test init.
function H.child()
    local child = MiniTest.new_child_neovim()
    child.setup = function()
        child.restart({ "-u", H.root .. "/tests/init.lua" })
        child.o.lines, child.o.columns = 40, 160
    end
    return child
end

--- Wait in the child until `expr` (Lua expression string) is truthy.
function H.wait_child(child, expr, timeout)
    local ok = vim.wait(timeout or 5000, function()
        return child.lua_get(expr) == true
    end, 50)
    if not ok then
        error("timed out waiting for: " .. expr, 2)
    end
end

-- Herdr ----------------------------------------------------------------------------

--- The herdr binary under test: $HERDR_BIN, else `herdr` on PATH.
function H.herdr_bin()
    local bin = vim.env.HERDR_BIN
    if bin and bin ~= "" then
        return vim.fn.executable(bin) == 1 and bin or nil
    end
    return vim.fn.exepath("herdr") ~= "" and vim.fn.exepath("herdr") or nil
end

local server_count = 0

--- Start an isolated Herdr server (its own config/state dirs and session).
--- Returns a server object; children started afterwards inherit its env.
function H.start_herdr()
    local bin = H.herdr_bin()
    if not bin then
        MiniTest.skip("no herdr binary (set HERDR_BIN or install herdr)")
    end
    server_count = server_count + 1
    -- Short path: unix socket paths are limited to ~104 bytes on macOS.
    local dir = string.format("/tmp/hnt-%d-%d", vim.uv.os_getpid(), server_count)
    vim.fn.delete(dir, "rf")
    local env = {
        XDG_CONFIG_HOME = dir .. "/c",
        XDG_STATE_HOME = dir .. "/s",
        XDG_DATA_HOME = dir .. "/d",
        HERDR_DISABLE_SOUND = "1",
        SHELL = "/bin/sh",
        ENV = "",
        PS1 = "$ ",
    }
    local saved = {}
    for k, v in pairs(env) do
        vim.fn.mkdir(k:match("^XDG") and v or dir, "p")
        saved[k] = vim.env[k] or false
        vim.env[k] = v
    end
    local server = { bin = bin, dir = dir, session = "t", env = env }
    server.proc = vim.system({ bin, "--session", server.session, "server" }, { env = env, text = true })
    local ok = vim.wait(10000, function()
        local st = vim.system({ bin, "--session", server.session, "status", "server" }, { env = env, text = true })
            :wait()
        server.socket = (st.stdout or ""):match("socket:%s*(%S+)")
        return (st.stdout or ""):match("status:%s*running") ~= nil
    end, 100)
    if not ok then
        error("herdr server did not start")
    end

    --- Synchronous API request (one per connection, newline-delimited JSON).
    function server.request(method, params)
        local pipe = assert(vim.uv.new_pipe(false))
        local done, buf, err = false, "", nil
        pipe:connect(server.socket, function(cerr)
            if cerr then
                err, done = cerr, true
                return
            end
            pipe:write(vim.json.encode({ id = "t", method = method, params = params or vim.empty_dict() }) .. "\n")
            pipe:read_start(function(rerr, chunk)
                if rerr or not chunk or chunk:find("\n") then
                    buf = buf .. (chunk or "")
                    err, done = rerr, true
                    pipe:read_stop()
                    return
                end
                buf = buf .. chunk
            end)
        end)
        vim.wait(5000, function()
            return done
        end, 10)
        pipe:close()
        if err then
            error("herdr " .. method .. ": " .. tostring(err))
        end
        local msg = vim.json.decode(vim.split(buf, "\n")[1])
        if msg.error then
            error("herdr " .. method .. ": " .. vim.inspect(msg.error))
        end
        return msg.result
    end

    --- Restart the same server (same session, state and sockets).
    function server.restart()
        vim.system({ bin, "--session", server.session, "server", "stop" }, { env = env }):wait(5000)
        vim.wait(5000, function()
            local st = vim.system({ bin, "--session", server.session, "status", "server" }, { env = env, text = true })
                :wait()
            return (st.stdout or ""):match("status:%s*running") == nil
        end, 100)
        server.proc = vim.system({ bin, "--session", server.session, "server" }, { env = env, text = true })
        local up = vim.wait(10000, function()
            local st = vim.system({ bin, "--session", server.session, "status", "server" }, { env = env, text = true })
                :wait()
            return (st.stdout or ""):match("status:%s*running") ~= nil
        end, 100)
        if not up then
            error("herdr server did not restart")
        end
    end

    function server.stop()
        vim.system({ bin, "--session", server.session, "server", "stop" }, { env = env }):wait(5000)
        if server.proc then
            pcall(function()
                server.proc:kill(15)
            end)
        end
        vim.fn.delete(dir, "rf")
        for k, v in pairs(saved) do
            vim.env[k] = v or nil -- restore the runner's environment
        end
    end

    --- Create a space; returns { workspace, tab, root_pane }.
    function server.space(label)
        return server.request("workspace.create", { label = label, focus = false })
    end

    --- Wait until a pane's recent output contains `text`.
    function server.wait_output(pane_id, text, timeout)
        local found = vim.wait(timeout or 5000, function()
            local r = server.request("pane.read", { pane_id = pane_id, source = "recent", lines = 200 })
            return r.read.text:find(text, 1, true) ~= nil
        end, 100)
        if not found then
            error("pane " .. pane_id .. " never showed " .. vim.inspect(text), 2)
        end
    end

    return server
end

return H
