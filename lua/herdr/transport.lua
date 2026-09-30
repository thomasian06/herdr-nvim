-- Connection to a Herdr server, local or over SSH.
--
-- Local: talk to the session's API socket directly and attach terminals with
-- the local `herdr` binary.
--
-- Remote: one SSH ControlMaster connection per Neovim instance. The remote API
-- socket is forwarded to a local unix socket (OpenSSH streamlocal forwarding)
-- and terminal attaches reuse the same master, so opening a pane is instant.

local config = require("herdr.config")

local M = {}

---@type "idle"|"starting"|"ready"|"failed"
M.status = "idle"
M.error = nil
---@type string? local path of the API socket
M.api_socket = nil

local waiters = {}

-- vim.system callbacks run in a fast (libuv) context where most of the Vim API
-- is unavailable; hop back onto the main loop before doing anything.
local function system(cmd, cb)
    local ok, obj = pcall(vim.system, cmd, { text = true }, cb and vim.schedule_wrap(cb) or nil)
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
local run_dir, ctl_path, master

local function opts()
    return config.options
end

local function remote_prefix()
    local parts = {}
    for _, p in ipairs(opts().remote_path) do
        parts[#parts + 1] = p
    end
    parts[#parts + 1] = "$PATH"
    return "PATH=" .. table.concat(parts, ":") .. " "
end

local function remote_herdr(args)
    return remote_prefix() .. "exec herdr --session " .. vim.fn.shellescape(opts().session) .. " " .. args
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

local function parse_socket(stdout)
    return stdout and stdout:match("socket:%s*(%S+)")
end

local function start_local()
    local o = opts()
    system({ o.herdr_bin, "--session", o.session, "status", "server" }, function(res)
        if res.code == 127 then
            return finish("`" .. o.herdr_bin .. "` not found. Install Herdr (https://herdr.dev) or set `herdr_bin`.")
        end
        local sock = parse_socket(res.stdout)
        if res.code ~= 0 or not sock or not (res.stdout or ""):match("status:%s*running") then
            return finish(
                "herdr server for session '"
                    .. o.session
                    .. "' is not running:\n"
                    .. (res.stdout or "")
                    .. (res.stderr or "")
            )
        end
        M.api_socket = sock
        finish(nil)
    end)
end

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
        if tries <= 0 or (master and master:is_closing()) then
            return cb("could not establish SSH connection to " .. host .. ": " .. (res.stderr or ""))
        end
        vim.defer_fn(function()
            wait_for_master(host, tries - 1, cb)
        end, 100)
    end)
end

local function start_remote()
    local host = opts().remote
    -- Short path: unix socket paths are limited to ~104 bytes on macOS.
    run_dir = string.format("/tmp/herdr-nvim-%s-%d", vim.uv.os_get_passwd().uid, vim.uv.os_getpid())
    vim.fn.mkdir(run_dir, "p", tonumber("700", 8))
    ctl_path = run_dir .. "/ctl"
    local local_sock = run_dir .. "/api.sock"

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
        if M.status == "ready" then
            M.status = "idle" -- connection dropped; next use reconnects
            M.api_socket = nil
        elseif M.status == "starting" then
            finish("ssh to " .. host .. " exited (" .. res.code .. "): " .. (res.stderr or ""))
        end
    end)

    wait_for_master(host, 100, function(err)
        if err then
            return finish(err)
        end
        system(ssh({ host, remote_herdr("status server") }), function(res)
            local remote_sock = parse_socket(res.stdout)
            if not remote_sock or not (res.stdout or ""):match("status:%s*running") then
                return finish(
                    "herdr server for session '"
                        .. opts().session
                        .. "' is not running on "
                        .. host
                        .. ":\n"
                        .. (res.stdout or "")
                        .. (res.stderr or "")
                )
            end
            system(ssh({ "-O", "forward", "-L", local_sock .. ":" .. remote_sock, host }), function(fwd)
                if fwd.code ~= 0 then
                    return finish("failed to forward herdr API socket: " .. (fwd.stderr or ""))
                end
                M.api_socket = local_sock
                finish(nil)
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

--- Command that attaches to a Herdr terminal, for use in a Neovim :terminal,
--- plus a cleanup function to call once that job has exited.
---
--- Remote cleanup exists because killing an ssh client that shares a
--- ControlMaster connection does not reliably end the remote command: Coder's
--- SSH server, for one, keeps it running, and herdr then keeps the pane
--- attached (and size-locked). The remote command records its PID, and cleanup
--- hangs up exactly that process if it is still a herdr attach.
---@param terminal_id string
---@param takeover boolean?
---@return string[] cmd, fun() cleanup
function M.attach_cmd(terminal_id, takeover)
    local o = opts()
    if not o.remote then
        local cmd = { o.herdr_bin, "--session", o.session, "terminal", "attach", terminal_id }
        if takeover then
            cmd[#cmd + 1] = "--takeover"
        end
        return cmd, function() end
    end
    attach_seq = attach_seq + 1
    local pidfile = string.format("%s-%d.pid", M.pidfile_prefix(), attach_seq)
    local args = "terminal attach " .. vim.fn.shellescape(terminal_id) .. (takeover and " --takeover" or "")
    local remote_cmd = "echo $$ > " .. pidfile .. "; " .. remote_herdr(args)
    local cleanup_cmd = table.concat({
        "p=$(cat " .. pidfile .. " 2>/dev/null)",
        'if [ -n "$p" ] && ps -p "$p" -o args= 2>/dev/null | grep -q \'terminal attach\'; then kill -HUP "$p"; fi',
        "rm -f " .. pidfile,
    }, "; ")
    local host = o.remote
    return ssh({ "-tt", host, remote_cmd }),
        function()
            if M.status == "ready" then
                system(ssh({ host, cleanup_cmd }))
            end
        end
end

function M.describe()
    local o = opts()
    return (o.remote and (o.remote .. ":") or "local:") .. o.session
end

function M.shutdown()
    if ctl_path and opts().remote and M.status == "ready" then
        local host = opts().remote
        local prefix = M.pidfile_prefix()
        local list = "find /tmp -maxdepth 1 -name " .. vim.fn.shellescape(vim.fn.fnamemodify(prefix, ":t") .. "-*.pid")
        vim.system(ssh({ host, M.cleanup_script(list) })):wait(3000)
    end
    if ctl_path and opts().remote then
        vim.system(ssh({ "-O", "exit", opts().remote })):wait(2000)
    end
    if master and not master:is_closing() then
        master:kill(15)
    end
    if run_dir then
        vim.fn.delete(run_dir, "rf")
    end
    M.status = "idle"
    M.api_socket = nil
end

return M
