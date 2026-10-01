-- Connection to a Herdr server, local or over SSH.
--
-- Local: talk to the session's sockets directly.
--
-- Remote: one SSH connection per Neovim. If your ssh config already has a live
-- ControlMaster for the host (ControlPath), it is reused, so hosts that need
-- MFA or a password work once you have authenticated in a terminal; otherwise
-- herdr-nvim runs its own master. The session's API and client sockets are
-- forwarded over it to local unix sockets, like Herdr's own `--remote` client.
-- Terminals then attach with the local `herdr` through the forwarded client
-- socket (HERDR_SOCKET_PATH): any number of open panes costs no extra SSH
-- sessions, and closing one detaches immediately. Without a compatible local
-- `herdr`, terminals run `herdr terminal attach` on the remote instead.
--
-- A dropped connection (SSH master gone, server restarted) is reconnected
-- with backoff; `User HerdrDisconnected` / `User HerdrReconnected` fire.

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
---@type table? `herdr status server --json` of the connected server
M.server = nil
---@type "own"|"user"|nil whose SSH ControlMaster carries the connection
M.ssh_mode = nil
---@type string? herdr binary on the remote host
M.remote_bin = nil

local waiters = {}
local run_dir, ctl_path, master
local forwards = {} ---@type string[] "-L" specs added to the SSH master
local used_ssh_attach = false
local server_home ---@type string? cached per connection
local generation = 0 -- bumps on shutdown/drop so stale callbacks can bail out
local backoff ---@type number? seconds until the next reconnect attempt

--- Plugin options, with `remote`/`session` taken from the active connection
--- (`remote = false` means the local server).
local function opts()
    local c = require("herdr.connection").active
    return setmetatable({
        remote = c and c.remote or false,
        session = c and c.session or "main",
    }, { __index = config.options })
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

local function event(name, data)
    vim.api.nvim_exec_autocmds("User", { pattern = name, data = data })
end

--- Parse `herdr status server` output: JSON (0.9.0+), else "key: value" text.
---@return table { running: boolean, socket: string?, version: string?, compatible: boolean? }
function M.parse_status(stdout)
    local ok, data = pcall(vim.json.decode, stdout or "", { luanil = { object = true, array = true } })
    if ok and type(data) == "table" then
        data.running = data.running == true or data.status == "running"
        return data
    end
    local t = {}
    for line in (stdout or ""):gmatch("[^\n]+") do
        local k, v = line:match("^%s*([%w_]+):%s*(.-)%s*$")
        if k then
            t[k] = v
        end
    end
    return {
        running = t.status == "running",
        socket = t.socket,
        version = t.version,
        compatible = t.private_protocol_compatible == "yes",
    }
end

local reconnecting = false -- a connection was lost and is not back yet

local function finish(err)
    M.status = err and "failed" or "ready"
    M.error = err
    if not err and reconnecting then
        -- Back after a loss, by whichever path (the reconnect loop, or any
        -- request that needed the connection): tell the rest of the plugin.
        reconnecting = false
        backoff = nil
        vim.schedule(function()
            event("HerdrReconnected")
        end)
    end
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
            if st.running then
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
    local cmd = env and { o.herdr_bin, "status", "server", "--json" }
        or { o.herdr_bin, "--session", o.session, "status", "server", "--json" }
    system(cmd, function(res)
        local st = M.parse_status(res.stdout)
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
        if st.running and st.socket then
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

--- ssh command through the connection's master (ours via -S, or the user's
--- via their ssh config). `ControlMaster=no` keeps these from ever becoming a
--- master: killing one must never end the user's other sessions.
local function ssh(args)
    local cmd = { "ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no" }
    if M.ssh_mode == "own" then
        vim.list_extend(cmd, { "-S", ctl_path })
    end
    vim.list_extend(cmd, args)
    return cmd
end

--- Effective ssh settings for a host (`ssh -G`), lowercase keys.
local function ssh_settings(host, cb)
    system({ "ssh", "-G", "--", host }, function(res)
        local settings = {}
        for line in (res.stdout or ""):gmatch("[^\n]+") do
            local k, v = line:match("^(%S+)%s+(.*)$")
            if k then
                settings[k:lower()] = v
            end
        end
        cb(settings)
    end)
end

--- Options for our own master: only what the user's config leaves unset, so
--- their choices (host keys, timeouts, proxies) always win.
function M.master_options(settings)
    local o = {
        "ControlPersist=no",
        "BatchMode=yes",
        "NumberOfPasswordPrompts=0",
        "StreamLocalBindUnlink=yes",
        "ExitOnForwardFailure=yes",
    }
    if (settings.serveraliveinterval or "0") == "0" then
        vim.list_extend(o, { "ServerAliveInterval=15", "ServerAliveCountMax=4" })
    end
    local timeout = settings.connecttimeout
    if timeout == nil or timeout == "0" or timeout == "none" then
        o[#o + 1] = "ConnectTimeout=15"
    end
    local out = {}
    for _, kv in ipairs(o) do
        vim.list_extend(out, { "-o", kv })
    end
    return out
end

-- Where Herdr may be installed on the remote: PATH (not mise shims), then
-- `remote_path`, then known install roots; confirmed with `status client`.
local KNOWN_PATHS = {
    "$HOME/.local/bin/herdr",
    "/opt/homebrew/bin/herdr",
    "/usr/local/bin/herdr",
    "/home/linuxbrew/.linuxbrew/bin/herdr",
    "$HOME/.nix-profile/bin/herdr",
    "/etc/profiles/per-user/$USER/bin/herdr",
    "/nix/var/nix/profiles/default/bin/herdr",
    "/run/current-system/sw/bin/herdr",
}

function M.find_herdr_script()
    local candidates = { '"$c"' }
    for _, dir in ipairs(opts().remote_path or {}) do
        candidates[#candidates + 1] = '"' .. dir:gsub('"', "") .. '/herdr"'
    end
    for _, p in ipairs(KNOWN_PATHS) do
        candidates[#candidates + 1] = '"' .. p .. '"'
    end
    return table.concat({
        "c=$(command -v herdr 2>/dev/null || :)",
        'case "$c" in */mise/shims/*) c= ;; /*) ;; *) c= ;; esac',
        "for p in " .. table.concat(candidates, " ") .. "; do",
        '  if [ -n "$p" ] && [ -x "$p" ] && "$p" status client --json </dev/null >/dev/null 2>&1; then',
        '    printf "%s\\n" "$p"; exit 0',
        "  fi",
        "done",
        "exit 127",
    }, "\n")
end

local function remote_herdr(args, exec)
    return (exec == false and "" or "exec ")
        .. vim.fn.shellescape(M.remote_bin or "herdr")
        .. " --session "
        .. vim.fn.shellescape(opts().session)
        .. " "
        .. args
end

local function remote_status(cb)
    system(ssh({ opts().remote, remote_herdr("status server --json") }), function(res)
        local st = M.parse_status(res.stdout)
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
        if st.compatible == true then
            M.attach_reason = nil
            return cb("forwarded")
        end
        M.attach_reason = "local herdr is not protocol-compatible with the server"
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
    run_dir = string.format("/tmp/herdr-nvim-%d-%d", vim.uv.os_get_passwd().uid, vim.uv.os_getpid())
    vim.fn.mkdir(run_dir, "p")
    vim.uv.fs_chmod(run_dir, tonumber("700", 8)) -- private: holds the control socket
    forwards = {}

    local function forward(st)
        M.server = st
        local remote_api = st.socket
        local stem = vim.fn.fnamemodify(remote_api, ":t:r")
        local remote_client = vim.fn.fnamemodify(remote_api, ":h") .. "/" .. stem .. "-client.sock"
        local specs = {
            run_dir .. "/herdr.sock:" .. remote_api,
            run_dir .. "/herdr-client.sock:" .. remote_client,
        }
        local args = { "-O", "forward" }
        for _, spec in ipairs(specs) do
            vim.list_extend(args, { "-L", spec })
        end
        args[#args + 1] = host
        system(ssh(args), function(res)
            if gen ~= generation then
                return
            end
            if res.code ~= 0 then
                return finish("failed to forward herdr sockets: " .. (res.stderr or ""))
            end
            forwards = specs
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

    local function with_server()
        remote_status(function(st)
            if gen ~= generation then
                return
            end
            if st.running and st.socket then
                return forward(st)
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
    end

    local function connected()
        system(ssh({ host, "sh -c " .. vim.fn.shellescape(M.find_herdr_script()) }), function(res)
            if gen ~= generation then
                return
            end
            local bin = vim.trim(res.stdout or ""):match("^(/%S+)")
            if res.code ~= 0 or not bin then
                return finish(
                    "herdr not found on "
                        .. host
                        .. " (searched PATH, remote_path and the usual install locations)"
                        .. ((res.stderr or "") ~= "" and (":\n" .. res.stderr) or "")
                )
            end
            M.remote_bin = bin
            with_server()
        end)
    end

    local function start_own_master(settings)
        M.ssh_mode = "own"
        ctl_path = run_dir .. "/ctl"
        local cmd = { "ssh", "-M", "-N", "-S", ctl_path }
        vim.list_extend(cmd, M.master_options(settings))
        vim.list_extend(cmd, { "--", host })
        master = system(cmd, function(res)
            if gen ~= generation then
                return
            end
            if M.status == "ready" then
                M.lost("SSH connection to " .. host .. " closed")
            elseif M.status == "starting" then
                finish("ssh to " .. host .. " exited (" .. res.code .. "): " .. (res.stderr or ""))
            end
        end)
        local tries = 150
        local function wait()
            system(ssh({ "-O", "check", host }), function(res)
                if gen ~= generation then
                    return
                end
                if res.code == 0 then
                    return connected()
                end
                tries = tries - 1
                if tries <= 0 or not master or master:is_closing() then
                    return -- the master's exit handler reports the error
                end
                vim.defer_fn(wait, 100)
            end)
        end
        wait()
    end

    ssh_settings(host, function(settings)
        if gen ~= generation then
            return
        end
        local cp = settings.controlpath
        if cp and cp ~= "none" then
            -- The user's own master (e.g. authenticated with MFA): reuse if live.
            M.ssh_mode = "user"
            return system(ssh({ "-O", "check", host }), function(res)
                if gen ~= generation then
                    return
                end
                if res.code == 0 then
                    return connected()
                end
                start_own_master(settings)
            end)
        end
        start_own_master(settings)
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

-- Dropped connections ------------------------------------------------------------

local function release_remote()
    local host = opts().remote
    if host and M.ssh_mode == "user" then
        -- Leave the user's master running; remove only our forwards.
        for _, spec in ipairs(forwards) do
            vim.system(ssh({ "-O", "cancel", "-L", spec, host })):wait(2000)
        end
    elseif host and ctl_path then
        vim.system(ssh({ "-O", "exit", host })):wait(2000)
    end
    if master and not master:is_closing() then
        master:kill(15)
    end
    if run_dir then
        vim.fn.delete(run_dir, "rf")
    end
    run_dir, ctl_path, master = nil, nil, nil
    forwards = {}
end

local function reset_state()
    M.api_socket = nil
    M.attach_mode = nil
    M.attach_reason = nil
    M.server = nil
    M.ssh_mode = nil
    M.remote_bin = nil
    server_home = nil
    used_ssh_attach = false
end

local function schedule_reconnect()
    local connection = require("herdr.connection")
    local target = connection.active
    if not target then
        return
    end
    backoff = math.min((backoff or 0.5) * 2, 30)
    local gen = generation
    vim.defer_fn(function()
        if gen ~= generation or connection.active ~= target or M.status == "ready" then
            return
        end
        M.ensure(function(err)
            if err then
                return schedule_reconnect()
            end
        end)
    end, backoff * 1000)
end

--- The connection dropped (SSH master gone, server restarted, socket gone):
--- forget it and reconnect with backoff (1s doubling to 30s).
function M.lost(reason)
    if M.status ~= "ready" then
        return
    end
    generation = generation + 1
    release_remote()
    reset_state()
    M.status = "idle"
    M.error = reason
    reconnecting = true
    event("HerdrDisconnected", { reason = reason })
    schedule_reconnect()
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

--- Resolve a path on the Herdr server: `~` is the server's home. cb(path?)
function M.resolve_path(path, cb)
    if not path then
        return cb(nil)
    end
    if path ~= "~" and path:sub(1, 2) ~= "~/" then
        return cb(path)
    end
    local function expand(home)
        cb(home and (home .. path:sub(2)) or nil)
    end
    if not opts().remote then
        return expand(vim.uv.os_homedir())
    end
    if server_home then
        return expand(server_home)
    end
    M.ensure(function(err)
        if err then
            return cb(nil)
        end
        system(ssh({ opts().remote, 'printf %s "$HOME"' }), function(res)
            if res.code == 0 and (res.stdout or ""):match("^/") then
                server_home = res.stdout
            end
            expand(server_home)
        end)
    end)
end

function M.describe()
    local o = opts()
    return (o.remote and (o.remote .. ":") or "local:") .. o.session
end

--- Disconnect: release the SSH connection and forget everything about the server.
function M.shutdown()
    generation = generation + 1
    backoff = nil
    reconnecting = false
    local o = opts()
    if run_dir and o.remote and M.status == "ready" and used_ssh_attach then
        local prefix = M.pidfile_prefix()
        local list = "find /tmp -maxdepth 1 -name " .. vim.fn.shellescape(vim.fn.fnamemodify(prefix, ":t") .. "-*.pid")
        vim.system(ssh({ o.remote, M.cleanup_script(list) })):wait(3000)
    end
    release_remote()
    reset_state()
    M.status = "idle"
    M.error = nil
    -- Anyone still waiting on the old connection gets an error.
    finish("disconnected")
    M.status = "idle"
    M.error = nil
end

return M
