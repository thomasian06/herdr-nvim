-- Connection to a Herdr server, local or over SSH.
--
-- Local: talk to the session's sockets directly.
--
-- Remote: exactly one SSH connection (a ControlMaster) per Neovim. The remote
-- session's API socket and client socket are forwarded to local unix sockets,
-- like Herdr's own `--remote` client does with its bridge. Terminals then
-- attach with the local `herdr` binary through the forwarded client socket
-- (HERDR_SOCKET_PATH), so any number of open panes costs no extra SSH sessions,
-- and closing one detaches immediately.
--
-- If there is no local `herdr`, or its protocol is incompatible with the
-- server, terminals fall back to running `herdr terminal attach` on the remote
-- over the same connection (one SSH session per open pane).

local config = require("herdr.config")

local M = {}

---@type "idle"|"starting"|"ready"|"failed"
M.status = "idle"
M.error = nil
---@type string? local path of the API socket
M.api_socket = nil
---@type "direct"|"forwarded"|"ssh"|nil how terminals attach
M.attach_mode = nil
---@type string? why the fallback attach mode was chosen
M.attach_reason = nil
---@type table<string, string>? parsed `herdr status server` of the connected server
M.server = nil

local waiters = {}
local run_dir, ctl_path, master
local used_ssh_attach = false
local generation = 0 -- bumps on shutdown so stale callbacks can bail out

local function opts()
    return config.options
end

-- vim.system callbacks run in a fast (libuv) context where most of the Vim API
-- is unavailable; hop back onto the main loop before doing anything.
local function system(cmd, cb, sys_opts)
    local o = vim.tbl_extend("force", { text = true }, sys_opts or {})
    local ok, obj = pcall(vim.system, cmd, o, cb and vim.schedule_wrap(cb) or nil)
    if ok then
        return obj
    end
    -- Spawn failed (e.g. binary not installed): report it like a failed run.
    if cb then
        vim.schedule(function()
            local reason = tostring(obj):find("ENOENT", 1, true) and "command not found" or tostring(obj)
            cb({ code = 127, signal = 0, stdout = "", stderr = cmd[1] .. ": " .. reason })
        end)
    end
    return nil
end

local function remote_prefix()
    local parts = {}
    for _, p in ipairs(opts().remote_path) do
        parts[#parts + 1] = p
    end
    parts[#parts + 1] = "$PATH"
    return "PATH=" .. table.concat(parts, ":") .. " "
end

local function remote_herdr(args, exec)
    return remote_prefix()
        .. (exec == false and "" or "exec ")
        .. "herdr --session "
        .. vim.fn.shellescape(opts().session)
        .. " "
        .. args
end

--- Parse `herdr status ...` output ("key: value" lines).
local function parse_status(stdout)
    local t = {}
    for line in (stdout or ""):gmatch("[^\n]+") do
        local k, v = line:match("^%s*([%w_]+):%s*(.-)%s*$")
        if k then
            t[k] = v
        end
    end
    return t
end

local function finish(err)
    M.status = err and "failed" or "ready"
    M.error = err
    local list = waiters
    waiters = {}
    for _, cb in ipairs(list) do
        vim.schedule(function()
            cb(err)
        end)
    end
end

local function not_running_msg(where)
    return string.format("herdr server for session '%s' is not running%s", opts().session, where)
end

--- Ask (per `auto_start`) whether to start a missing server. cb(start: boolean)
local function confirm_start(where, cb)
    local mode = opts().auto_start
    if mode == true then
        return cb(true)
    elseif mode == false then
        return cb(false)
    end
    vim.ui.select({ "Start it", "Cancel" }, {
        prompt = not_running_msg(where) .. ". Start it?",
    }, function(choice)
        cb(choice == "Start it")
    end)
end

--- Poll `status_fn(cb(status))` until the server runs or the deadline passes.
local function wait_running(status_fn, deadline_ms, cb)
    local t0 = vim.uv.now()
    local function poll()
        status_fn(function(st)
            if st.status == "running" then
                return cb(st)
            end
            if vim.uv.now() - t0 > deadline_ms then
                return cb(nil)
            end
            vim.defer_fn(poll, 250)
        end)
    end
    poll()
end

-- Local ------------------------------------------------------------------------

local function local_status(cb, env)
    local o = opts()
    local cmd = env and { o.herdr_bin, "status", "server" }
        or { o.herdr_bin, "--session", o.session, "status", "server" }
    system(cmd, function(res)
        local st = parse_status(res.stdout)
        st._code = res.code
        st._stderr = res.stderr
        cb(st)
    end, env and { env = env } or nil)
end

local function start_local()
    local o = opts()
    local gen = generation
    local function connected(st)
        M.server = st
        M.api_socket = st.socket
        M.attach_mode = "direct"
        finish(nil)
    end
    local_status(function(st)
        if gen ~= generation then
            return
        end
        if st._code == 127 then
            return finish("`" .. o.herdr_bin .. "` not found. Install Herdr (https://herdr.dev) or set `herdr_bin`.")
        end
        if st.status == "running" and st.socket then
            return connected(st)
        end
        confirm_start("", function(start)
            if not start then
                return finish(not_running_msg("") .. ".")
            end
            system({ o.herdr_bin, "--session", o.session, "server" }, nil, { detach = true, stdin = false })
            wait_running(local_status, 5000, function(ok)
                if gen ~= generation then
                    return
                end
                if ok and ok.socket then
                    connected(ok)
                else
                    finish("started herdr server for session '" .. o.session .. "', but it did not come up")
                end
            end)
        end)
    end)
end

-- Remote -----------------------------------------------------------------------

local function ssh(args)
    local cmd = { "ssh", "-S", ctl_path, "-o", "BatchMode=yes" }
    vim.list_extend(cmd, args)
    return cmd
end

local function wait_for_master(host, tries, cb)
    system(ssh({ "-O", "check", host }), function(res)
        if res.code == 0 then
            return cb(nil)
        end
        if tries <= 0 or not master or master:is_closing() then
            return cb("could not establish SSH connection to " .. host .. ": " .. (res.stderr or ""))
        end
        vim.defer_fn(function()
            wait_for_master(host, tries - 1, cb)
        end, 100)
    end)
end

local function remote_status(cb)
    system(ssh({ opts().remote, remote_herdr("status server") }), function(res)
        local st = parse_status(res.stdout)
        st._code = res.code
        st._stderr = res.stderr
        cb(st)
    end)
end

--- Start the remote server detached, the way herdr's own bridge does.
local function remote_start_cmd()
    local server = remote_herdr("server", false)
    return "if command -v setsid >/dev/null 2>&1; then "
        .. ("setsid " .. server)
        .. "; else "
        .. ("nohup " .. server)
        .. "; fi </dev/null >/dev/null 2>&1 &"
end

--- Decide how terminals attach once the sockets are forwarded.
local function choose_attach(cb)
    local o = opts()
    if o.remote_attach == "ssh" then
        M.attach_reason = 'remote_attach = "ssh"'
        return cb("ssh")
    end
    if vim.fn.executable(o.herdr_bin) ~= 1 then
        M.attach_reason = "no local `" .. o.herdr_bin .. "`"
        return cb("ssh")
    end
    local_status(function(st)
        if st.private_protocol_compatible == "yes" then
            M.attach_reason = nil
            return cb("forwarded")
        end
        M.attach_reason = string.format(
            "local herdr is not protocol-compatible with the server (%s)",
            st.private_protocol_compatible or ("exit " .. tostring(st._code))
        )
        cb("ssh")
    end, { HERDR_SOCKET_PATH = run_dir .. "/herdr.sock" })
end

--- Clean up after Neovim instances that died without shutting down (crash,
--- kill -9): stop their orphaned SSH masters and remove their run dirs.
local function sweep_stale_run_dirs()
    local uid = vim.uv.os_get_passwd().uid
    for _, dir in ipairs(vim.fn.glob("/tmp/herdr-nvim-" .. uid .. "-*", false, true)) do
        local pid = tonumber(dir:match("%-(%d+)$"))
        local alive = pid and (pid == vim.uv.os_getpid() or vim.uv.kill(pid, 0) == 0)
        if pid and not alive then
            if vim.uv.fs_stat(dir .. "/ctl") then
                pcall(function()
                    vim.system({ "ssh", "-S", dir .. "/ctl", "-O", "exit", "herdr-nvim-stale" }):wait(2000)
                end)
            end
            vim.fn.delete(dir, "rf")
        end
    end
end

local function start_remote()
    local host = opts().remote
    local gen = generation
    sweep_stale_run_dirs()
    -- Short path: unix socket paths are limited to ~104 bytes on macOS.
    run_dir = string.format("/tmp/herdr-nvim-%s-%d", vim.uv.os_get_passwd().uid, vim.uv.os_getpid())
    vim.fn.mkdir(run_dir, "p", tonumber("700", 8))
    ctl_path = run_dir .. "/ctl"

    master = system({
        "ssh",
        "-M",
        "-N",
        "-S",
        ctl_path,
        "-o",
        "ControlPersist=no",
        "-o",
        "BatchMode=yes",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "StreamLocalBindUnlink=yes",
        "-o",
        "ExitOnForwardFailure=yes",
        host,
    }, function(res)
        if gen ~= generation then
            return
        end
        if M.status == "ready" then
            M.status = "idle" -- connection dropped; next use reconnects
            M.api_socket = nil
        elseif M.status == "starting" then
            finish("ssh to " .. host .. " exited (" .. res.code .. "): " .. (res.stderr or ""))
        end
    end)

    local function forward(st)
        M.server = st
        local remote_api = st.socket
        local stem = vim.fn.fnamemodify(remote_api, ":t:r")
        local remote_client = vim.fn.fnamemodify(remote_api, ":h") .. "/" .. stem .. "-client.sock"
        local fwd = { "-O", "forward" }
        vim.list_extend(fwd, { "-L", run_dir .. "/herdr.sock:" .. remote_api })
        vim.list_extend(fwd, { "-L", run_dir .. "/herdr-client.sock:" .. remote_client, host })
        system(ssh(fwd), function(res)
            if gen ~= generation then
                return
            end
            if res.code ~= 0 then
                return finish("failed to forward herdr sockets: " .. (res.stderr or ""))
            end
            M.api_socket = run_dir .. "/herdr.sock"
            choose_attach(function(mode)
                if gen ~= generation then
                    return
                end
                M.attach_mode = mode
                finish(nil)
            end)
        end)
    end

    wait_for_master(host, 100, function(err)
        if gen ~= generation then
            return
        end
        if err then
            return finish(err)
        end
        remote_status(function(st)
            if gen ~= generation then
                return
            end
            if st.status == "running" and st.socket then
                return forward(st)
            end
            if st._code == 127 or (st._stderr or ""):find("not found", 1, true) then
                return finish(
                    "herdr not found on "
                        .. host
                        .. " (searched "
                        .. table.concat(opts().remote_path, ", ")
                        .. " and PATH):\n"
                        .. (st._stderr or "")
                )
            end
            confirm_start(" on " .. host, function(start)
                if not start then
                    return finish(not_running_msg(" on " .. host) .. ".")
                end
                system(ssh({ host, remote_start_cmd() }), function()
                    wait_running(remote_status, 8000, function(ok)
                        if gen ~= generation then
                            return
                        end
                        if ok and ok.socket then
                            forward(ok)
                        else
                            finish("started herdr server on " .. host .. ", but it did not come up")
                        end
                    end)
                end)
            end)
        end)
    end)
end

--- Ensure the connection is up, then call cb(err).
function M.ensure(cb)
    if M.status == "ready" then
        return vim.schedule(function()
            cb(nil)
        end)
    end
    waiters[#waiters + 1] = cb
    if M.status == "starting" then
        return
    end
    M.status = "starting"
    M.error = nil
    if opts().remote then
        start_remote()
    else
        start_local()
    end
end

-- Terminal attach ----------------------------------------------------------

local attach_seq = 0

function M.pidfile_prefix()
    return string.format("/tmp/herdr-nvim-%s-%d", vim.uv.os_get_passwd().username, vim.uv.os_getpid())
end

--- Remote shell snippet: for each pidfile printed by `list_cmd`, hang up the
--- recorded process if it is still a herdr attach, then remove the pidfile.
function M.cleanup_script(list_cmd)
    return list_cmd
        .. " | while read -r f; do "
        .. 'p=$(cat "$f" 2>/dev/null); '
        .. 'if [ -n "$p" ] && ps -p "$p" -o args= 2>/dev/null | grep -q \'terminal attach\'; then kill -HUP "$p"; fi; '
        .. 'rm -f "$f"; done'
end

--- Command (and env) that attaches to a Herdr terminal, for a Neovim
--- :terminal, plus a cleanup function to call once that job has exited.
---
--- Only the ssh fallback needs cleanup: killing an ssh client that shares a
--- ControlMaster does not reliably end the remote command (Coder's SSH server,
--- for one, keeps it running), and herdr would keep the pane attached. The
--- remote command records its PID so cleanup can hang up exactly that process.
---@param terminal_id string
---@param takeover boolean?
---@return string[] cmd, fun() cleanup, table<string, string>? env
function M.attach_cmd(terminal_id, takeover)
    local o = opts()
    local noop = function() end
    if M.attach_mode == "direct" or not o.remote then
        local cmd = { o.herdr_bin, "--session", o.session, "terminal", "attach", terminal_id }
        if takeover then
            cmd[#cmd + 1] = "--takeover"
        end
        return cmd, noop, nil
    end
    if M.attach_mode == "forwarded" then
        local cmd = { o.herdr_bin, "terminal", "attach", terminal_id }
        if takeover then
            cmd[#cmd + 1] = "--takeover"
        end
        return cmd, noop, { HERDR_SOCKET_PATH = run_dir .. "/herdr.sock" }
    end
    used_ssh_attach = true
    attach_seq = attach_seq + 1
    local pidfile = string.format("%s-%d.pid", M.pidfile_prefix(), attach_seq)
    local args = "terminal attach " .. vim.fn.shellescape(terminal_id) .. (takeover and " --takeover" or "")
    local remote_cmd = "echo $$ > " .. pidfile .. "; " .. remote_herdr(args)
    local cleanup_cmd = M.cleanup_script("echo " .. pidfile)
    local host = o.remote
    return ssh({ "-tt", host, remote_cmd }),
        function()
            if M.status == "ready" then
                system(ssh({ host, cleanup_cmd }))
            end
        end,
        nil
end

function M.describe()
    local o = opts()
    return (o.remote and (o.remote .. ":") or "local:") .. o.session
end

--- Disconnect: stop the SSH master and forget everything about the server.
function M.shutdown()
    generation = generation + 1
    local o = opts()
    if ctl_path and o.remote and M.status == "ready" and used_ssh_attach then
        local prefix = M.pidfile_prefix()
        local list = "find /tmp -maxdepth 1 -name " .. vim.fn.shellescape(vim.fn.fnamemodify(prefix, ":t") .. "-*.pid")
        vim.system(ssh({ o.remote, M.cleanup_script(list) })):wait(3000)
    end
    if ctl_path and o.remote then
        vim.system(ssh({ "-O", "exit", o.remote })):wait(2000)
    end
    if master and not master:is_closing() then
        master:kill(15)
    end
    if run_dir then
        vim.fn.delete(run_dir, "rf")
    end
    run_dir, ctl_path, master = nil, nil, nil
    used_ssh_attach = false
    M.status = "idle"
    M.error = nil
    M.api_socket = nil
    M.attach_mode = nil
    M.attach_reason = nil
    M.server = nil
    -- Anyone still waiting on the old connection gets an error.
    finish("disconnected")
    M.status = "idle"
    M.error = nil
end

return M
