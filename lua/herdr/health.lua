-- :checkhealth herdr
local M = {}
local health = vim.health

local function run(cmd, timeout)
    local ok, obj = pcall(vim.system, cmd, { text = true })
    if not ok then
        return { code = 127, stdout = "", stderr = tostring(obj) }
    end
    return obj:wait(timeout or 20000)
end

-- The versions CI tests; older ones are not supported.
local MIN_NVIM = "0.12"
local MIN_HERDR = "0.9.3"

--- Report a `herdr --version` output, warning when it is older than supported.
local function herdr_version(label, output)
    local text = vim.trim(output or "")
    local v = text:match("(%d+%.%d+%.%d+)")
    if v and vim.version.lt(v, MIN_HERDR) then
        health.warn(("%s: %s (herdr-nvim needs Herdr %s+)"):format(label, text, MIN_HERDR))
    else
        health.ok(label .. ": " .. (text ~= "" and text or "herdr"))
    end
end

function M.check()
    local config = require("herdr.config")
    local connection = require("herdr.connection")
    local transport = require("herdr.transport")
    local o = config.options
    local c = connection.current()

    health.start("herdr-nvim: Neovim")
    if vim.fn.has("nvim-" .. MIN_NVIM) == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("Neovim " .. MIN_NVIM .. "+ is required (found " .. tostring(vim.version()) .. ")")
    end
    if package.loaded["snacks"] then
        health.ok("snacks.nvim found: picker with live preview, explorer styling")
    else
        health.info("snacks.nvim not found (optional): picker falls back to vim.ui.select")
    end

    health.start("herdr-nvim: connection")
    local want = vim.g.herdr_connection
    if want ~= nil and want ~= "" then
        health.info("project connection (vim.g.herdr_connection): " .. vim.inspect(want))
    elseif vim.o.exrc then
        health.info("no vim.g.herdr_connection here; connect with :Herdr connect")
    else
        health.info("'exrc' is off: set vim.o.exrc = true to use a project's .nvim.lua (vim.g.herdr_connection)")
    end
    if not c then
        health.info("not connected")
        local local_herdr = vim.fn.executable(o.herdr_bin) == 1
        if local_herdr then
            herdr_version("local herdr", run({ o.herdr_bin, "--version" }).stdout)
        else
            health.info("local herdr not installed (needed for a local server; recommended for remote)")
        end
        if vim.fn.executable("ssh") ~= 1 then
            health.warn("ssh not found (needed for remote servers)")
        end
        return
    end
    health.info("connected to " .. connection.label(c))
    local local_herdr = vim.fn.executable(o.herdr_bin) == 1
    if local_herdr then
        herdr_version("local herdr", run({ o.herdr_bin, "--version" }).stdout)
    elseif c.remote then
        health.info(
            "local herdr not installed (optional for remote): terminals will attach by running herdr on the remote,"
                .. " one SSH session per open terminal"
        )
    else
        health.error("`" .. o.herdr_bin .. "` not found; install Herdr (https://herdr.dev) or set `herdr_bin`")
    end

    if not c.remote then
        if local_herdr then
            local st = transport.parse_status(
                run({ o.herdr_bin, "--session", c.session, "status", "server", "--json" }).stdout
            )
            if st.running then
                health.ok("server running (" .. tostring(st.version or "?") .. ")")
            else
                health.warn("server for session '" .. c.session .. "' is not running (it can be started on connect)")
            end
        end
    else
        if vim.fn.executable("ssh") ~= 1 then
            health.error("ssh not found")
            return
        end
        local settings = run({ "ssh", "-G", "--", c.remote }).stdout or ""
        local cp = settings:match("\ncontrolpath (%S+)") or settings:match("^controlpath (%S+)")
        if cp and cp ~= "none" then
            local live = run({ "ssh", "-o", "BatchMode=yes", "-O", "check", c.remote }).code == 0
            health.info(
                "ssh config has a ControlPath for "
                    .. c.remote
                    .. (live and ": its live master is reused" or ": no live master, herdr-nvim starts its own")
            )
        end
        local probe = run({
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=15",
            "--",
            c.remote,
            "sh -c " .. vim.fn.shellescape(transport.find_herdr_script()),
        }, 45000)
        if probe.code == 255 then
            health.error(
                "cannot SSH to " .. c.remote .. " non-interactively (ssh -o BatchMode=yes):\n" .. (probe.stderr or "")
            )
            return
        end
        health.ok("ssh " .. c.remote .. " works non-interactively")
        local bin = vim.trim(probe.stdout or ""):match("^(/%S+)")
        if not bin then
            health.error(
                "herdr not found on " .. c.remote .. " (searched PATH, remote_path and the usual install locations)"
            )
            return
        end
        local q = vim.fn.shellescape(bin)
        local info = run({
            "ssh",
            "-o",
            "BatchMode=yes",
            "--",
            c.remote,
            q .. " --version; " .. q .. " --session " .. vim.fn.shellescape(c.session) .. " status server --json",
        }, 45000)
        herdr_version("remote herdr at " .. bin, (info.stdout or ""):match("^(herdr [^\n]+)"))
        local st = transport.parse_status((info.stdout or ""):match("\n(%b{})") or "")
        if st.running then
            health.ok("remote server running (" .. tostring(st.version or "?") .. ")")
        else
            health.warn("remote server for session '" .. c.session .. "' is not running (it can be started on connect)")
        end
    end

    if transport.status == "ready" then
        local how = ({
            direct = "local sockets",
            forwarded = "local herdr through the forwarded socket (one SSH connection, no extra sessions)",
            ssh = "herdr on the remote, one SSH session per open terminal",
        })[transport.attach_mode] or tostring(transport.attach_mode)
        health.info(
            "terminals attach via " .. how .. (transport.attach_reason and (" - " .. transport.attach_reason) or "")
        )
    else
        health.info("not connected yet; open the tree (:Herdr) to connect")
    end
end

return M
