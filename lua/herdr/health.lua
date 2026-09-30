-- :checkhealth herdr
local M = {}

local function run(cmd, timeout)
    local ok, obj = pcall(vim.system, cmd, { text = true })
    if not ok then
        return { code = 127, stdout = "", stderr = tostring(obj) }
    end
    return obj:wait(timeout or 20000)
end

local function status_field(stdout, key)
    return (stdout or ""):match(key .. ":%s*([^\n]+)")
end

function M.check()
    local health = vim.health
    local config = require("herdr.config")
    local connection = require("herdr.connection")
    local transport = require("herdr.transport")
    local o = config.options
    local c = connection.current()

    health.start("herdr-nvim: Neovim")
    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("Neovim 0.10+ is required")
    end
    if package.loaded["snacks"] then
        health.ok("snacks.nvim found: picker with live preview, explorer styling")
    else
        health.info("snacks.nvim not found (optional): picker falls back to vim.ui.select")
    end

    health.start("herdr-nvim: connection")
    local project = connection.find_project()
    if project then
        local trusted = vim.secure.trust
            and (function()
                local ok, list = pcall(function()
                    return vim.fn.readfile(vim.fn.stdpath("state") .. "/trust")
                end)
                local path = vim.fn.fnamemodify(project, ":p")
                for _, line in ipairs(ok and list or {}) do
                    if line:find(path, 1, true) then
                        return true
                    end
                end
                return false
            end)()
        health.info(
            "project file: "
                .. vim.fn.fnamemodify(project, ":~")
                .. (trusted and " (trusted)" or " (not trusted yet; Neovim will ask on connect)")
        )
    else
        health.info("no " .. connection.PROJECT_FILE .. " here; connect manually with :Herdr connect")
    end
    if not c then
        health.info("not connected")
        local local_herdr = vim.fn.executable(o.herdr_bin) == 1
        if local_herdr then
            health.ok("local herdr: " .. vim.trim(run({ o.herdr_bin, "--version" }).stdout or ""))
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
        local v = run({ o.herdr_bin, "--version" })
        health.ok("local herdr: " .. vim.trim(v.stdout or ""))
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
            local st = run({ o.herdr_bin, "--session", c.session, "status", "server" })
            if status_field(st.stdout, "status") == "running" then
                health.ok("server running (" .. (status_field(st.stdout, "version") or "?") .. ")")
            else
                health.warn("server for session '" .. c.session .. "' is not running (it can be started on connect)")
            end
        end
    else
        if vim.fn.executable("ssh") ~= 1 then
            health.error("ssh not found")
            return
        end
        local probe = run({
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=15",
            c.remote,
            "PATH="
                .. table.concat(o.remote_path, ":")
                .. ":$PATH; herdr --version && herdr --session "
                .. vim.fn.shellescape(c.session)
                .. " status server",
        }, 45000)
        if probe.code == 255 then
            health.error(
                "cannot SSH to " .. c.remote .. " non-interactively (ssh -o BatchMode=yes):\n" .. (probe.stderr or "")
            )
            return
        end
        health.ok("ssh " .. c.remote .. " works non-interactively")
        local version = (probe.stdout or ""):match("^(herdr [^\n]+)")
        if not version then
            health.error(
                "herdr not found on " .. c.remote .. " (searched " .. table.concat(o.remote_path, ", ") .. " and PATH)"
            )
            return
        end
        health.ok("remote " .. version)
        if status_field(probe.stdout, "status") == "running" then
            health.ok("remote server running (" .. (status_field(probe.stdout, "version") or "?") .. ")")
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
