-- Connections: which Herdr server/session the plugin talks to.
--
-- A connection is { name?, remote?, session }. `remote = nil` means the local
-- Herdr server. At most one connection is active; nothing connects until you
-- ask (`:Herdr connect`), except a project file:
--
--   .herdr-nvim.json in the working directory or a parent, e.g.
--     { "remote": "devbox", "session": "main" }   or   { "profile": "devbox" }
--   connects when Neovim starts there, or when you :cd into it while
--   disconnected. It is read through vim.secure.read(), so Neovim asks you to
--   trust each file once (like 'exrc').
--
-- Known connections, offered by `:Herdr connect`:
--   - local Herdr (when `herdr` is installed)
--   - `profiles` (and `remote`/`session`) from setup()
--   - Herdr's own saved machines (`herdr machine list --json`)
--   - profiles saved with `:Herdr save`, stored with the last-used connection
--     in stdpath("data")/herdr-nvim/connections.json

local config = require("herdr.config")

local M = {}

M.PROJECT_FILE = ".herdr-nvim.json"

---@type table? the active connection, nil when disconnected
M.active = nil

local function store_path()
    return vim.fn.stdpath("data") .. "/herdr-nvim/connections.json"
end

local function read_store()
    local f = io.open(store_path(), "r")
    if not f then
        return { profiles = {} }
    end
    local ok, data = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
    f:close()
    if not ok or type(data) ~= "table" then
        return { profiles = {} }
    end
    data.profiles = data.profiles or {}
    return data
end

local function write_store(data)
    vim.fn.mkdir(vim.fn.fnamemodify(store_path(), ":h"), "p")
    local f = assert(io.open(store_path(), "w"))
    f:write(vim.json.encode(data))
    f:close()
end

local function normalize(c)
    return {
        name = c.name,
        remote = (c.remote ~= nil and c.remote ~= "" and c.remote ~= "local") and c.remote or nil,
        session = (c.session and c.session ~= "") and c.session or "main",
        projects_dir = (type(c.projects_dir) == "string" and c.projects_dir ~= "") and c.projects_dir or nil,
        source = c.source,
    }
end

--- Where new spaces start for the active connection (unexpanded), or nil.
function M.projects_dir()
    return (M.active and M.active.projects_dir) or config.options.projects_dir
end

--- Reject values that ssh (or herdr) could read as options or that could not
--- be a host/session name. Returns an error message, or nil when valid.
function M.validate(c)
    if c.remote and (c.remote:sub(1, 1) == "-" or c.remote:find("[%s%c]")) then
        return "invalid SSH target " .. vim.inspect(c.remote)
    end
    if c.session:sub(1, 1) == "-" or c.session:find("[%s%c/]") then
        return "invalid session name " .. vim.inspect(c.session)
    end
    if c.projects_dir and c.projects_dir:find("%c") then
        return "invalid projects_dir " .. vim.inspect(c.projects_dir)
    end
end

--- "host", "host:session", "local", "local:session".
function M.parse(target)
    local host, session = target:match("^(.-):([^:@/]+)$")
    host = host or target
    return normalize({ remote = host, session = session })
end

function M.label(c)
    if not c then
        return "not connected"
    end
    local where = (c.remote or "local") .. ":" .. c.session
    return c.name and c.name ~= where and (c.name .. " (" .. where .. ")") or where
end

function M.same(a, b)
    return a and b and a.remote == b.remote and a.session == b.session
end

---@return table? the active connection
function M.current()
    return M.active
end

--- Profiles from setup(): `profiles`, plus `remote`/`session` as one more.
local function config_profiles()
    local o = config.options
    local out = {}
    if o.remote then
        out[#out + 1] = { name = o.remote, remote = o.remote, session = o.session, projects_dir = o.projects_dir }
    end
    for _, p in ipairs(o.profiles or {}) do
        out[#out + 1] = p
    end
    return out
end

--- Gather known connections asynchronously. cb(list)
function M.list(cb)
    local out, seen = {}, {}
    local function add(c)
        c = normalize(c)
        local key = (c.remote or "") .. "\0" .. c.session
        if M.validate(c) then
            return
        end
        local existing = seen[key]
        if existing then
            -- Same server/session from several sources: keep the first entry,
            -- filling in what it lacks (e.g. projects_dir from a profile).
            existing.name = existing.name or c.name
            existing.projects_dir = existing.projects_dir or c.projects_dir
            return
        end
        seen[key] = c
        out[#out + 1] = c
    end
    local o = config.options
    if M.active then
        add(vim.tbl_extend("force", M.active, { source = "current" }))
    end
    local store = read_store()
    if store.last then
        add(vim.tbl_extend("force", store.last, { source = "last" }))
    end
    for _, p in ipairs(config_profiles()) do
        add(vim.tbl_extend("force", p, { source = "config" }))
    end
    for _, p in ipairs(store.profiles) do
        add(vim.tbl_extend("force", p, { source = "saved" }))
    end
    local has_local = vim.fn.executable(o.herdr_bin) == 1
    if has_local then
        add({ source = "local" })
    end
    if not has_local then
        return cb(out)
    end
    local ok = pcall(vim.system, { o.herdr_bin, "machine", "list", "--json" }, { text = true }, function(res)
        vim.schedule(function()
            local okj, machines = pcall(vim.json.decode, res.stdout or "")
            if res.code == 0 and okj and type(machines) == "table" then
                for _, m in ipairs(machines) do
                    if m.enabled ~= false and m.target then
                        add({ name = m.label, remote = m.target, session = m.session, source = "herdr" })
                    end
                end
            end
            cb(out)
        end)
    end)
    if not ok then
        cb(out)
    end
end

function M.save(name, c)
    c = normalize(c or M.active or {})
    local data = read_store()
    data.profiles = vim.tbl_filter(function(p)
        return p.name ~= name
    end, data.profiles)
    data.profiles[#data.profiles + 1] =
        { name = name, remote = c.remote, session = c.session, projects_dir = c.projects_dir }
    write_store(data)
end

function M.forget(name)
    local data = read_store()
    local before = #data.profiles
    data.profiles = vim.tbl_filter(function(p)
        return p.name ~= name
    end, data.profiles)
    write_store(data)
    return #data.profiles < before
end

function M.saved_names()
    local names = {}
    for _, p in ipairs(read_store().profiles) do
        names[#names + 1] = p.name
    end
    for _, p in ipairs(config_profiles()) do
        if p.name then
            names[#names + 1] = p.name
        end
    end
    return names
end

local function remember_last(c)
    local data = read_store()
    data.last = { name = c.name, remote = c.remote, session = c.session, projects_dir = c.projects_dir }
    write_store(data)
end

local connected_waiters = {}

--- Run fn once a connection is active; if there is none, ask for one first.
function M.with_connection(fn)
    if M.active then
        return fn()
    end
    connected_waiters[#connected_waiters + 1] = fn
    M.pick()
end

--- Switch to a connection: detach and close the old server's terminals,
--- disconnect, then connect to the new one.
function M.switch(c)
    c = normalize(c)
    local err = M.validate(c)
    if err then
        connected_waiters = {}
        return vim.notify("herdr: " .. err, vim.log.levels.ERROR)
    end
    local state = require("herdr.state")
    local transport = require("herdr.transport")
    if not (M.same(c, M.active) and transport.status ~= "failed") then
        if package.loaded["herdr.terminal"] then
            require("herdr.terminal").close_all()
        end
        state.reset()
        transport.shutdown()
    end
    M.active = c
    remember_last(c)
    state.start()
    local waiters = connected_waiters
    connected_waiters = {}
    for _, fn in ipairs(waiters) do
        vim.schedule(fn)
    end
end

function M.disconnect()
    if package.loaded["herdr.terminal"] then
        require("herdr.terminal").close_all()
    end
    require("herdr.state").reset()
    require("herdr.transport").shutdown()
    M.active = nil
    require("herdr.state").reset() -- re-render views as disconnected
end

--- Resolve "name", "host" or "host:session" to a connection. cb(conn)
function M.resolve(arg, cb)
    M.list(function(list)
        for _, c in ipairs(list) do
            if c.name == arg then
                return cb(c)
            end
        end
        cb(M.parse(arg))
    end)
end

-- Project file ---------------------------------------------------------------

--- Find the nearest project file at or above `dir`.
function M.find_project(dir)
    return vim.fs.find(M.PROJECT_FILE, { upward = true, path = dir or vim.fn.getcwd(), type = "file" })[1]
end

--- Parse project file contents into a connection ({ profile = ... } or a
--- connection). Returns nil and a reason when invalid.
local function parse_project(content)
    local ok, data = pcall(vim.json.decode, content or "", { luanil = { object = true, array = true } })
    if not ok or type(data) ~= "table" then
        return nil, "invalid JSON"
    end
    if data.profile then
        return { profile = tostring(data.profile), projects_dir = data.projects_dir }
    end
    local c = normalize({
        name = data.name,
        remote = data.remote,
        session = data.session,
        projects_dir = data.projects_dir,
    })
    local err = M.validate(c)
    if err then
        return nil, err
    end
    return c
end

--- Trust status of a file in Neovim's trust database (the one 'exrc' and
--- vim.secure use): "allowed" (and unchanged since), "denied", or "unknown".
function M.trust_status(path)
    local full = vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
    local f = io.open(full, "rb")
    if not f then
        return "unknown"
    end
    local hash = vim.fn.sha256(f:read("*a"))
    f:close()
    local db = io.open(vim.fn.stdpath("state") .. "/trust", "r")
    if not db then
        return "unknown"
    end
    local status = "unknown"
    for line in db:lines() do
        local h, p = line:match("^(%S+) (.+)$")
        if p == full then
            status = h == "!" and "denied" or (h == hash and "allowed" or "unknown")
        end
    end
    db:close()
    return status
end

--- Trust a file in Neovim's trust database. Before Neovim 0.12,
--- vim.secure.trust only accepts "allow" for a buffer, not a path.
function M.trust_allow(path)
    vim.fn.mkdir(vim.fn.stdpath("state"), "p") -- the database lives here
    if pcall(vim.secure.trust, { action = "allow", path = path }) then
        return
    end
    local existing = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
    local buf = existing ~= -1 and existing or vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.secure.trust({ action = "allow", bufnr = buf })
    if existing == -1 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

--- Read a trusted project file into a connection. Returns nil and a reason
--- when it is not trusted (Neovim asks, via vim.secure.read) or invalid.
function M.read_project(path)
    local content = vim.secure.read(path)
    if not content then
        return nil, "not trusted"
    end
    return parse_project(content)
end

--- Connect from a project file, if one applies. Never replaces an active
--- connection; tells you when the project asks for a different one.
--- Untrusted files are not read silently: you get a visible choice (trust and
--- connect / not now / never), recorded in Neovim's trust database.
function M.autoconnect(dir)
    local path = M.find_project(dir)
    if not path then
        return
    end
    local trust = M.trust_status(path)
    if trust == "denied" then
        return
    end
    local f = io.open(path, "r")
    local content = f and f:read("*a") or ""
    if f then
        f:close()
    end
    local c, err = parse_project(content)
    if not c then
        return vim.notify("herdr: " .. vim.fn.fnamemodify(path, ":~") .. ": " .. err, vim.log.levels.WARN)
    end
    local function go(conn)
        if M.active then
            if not M.same(conn, M.active) then
                vim.notify(
                    "herdr: "
                        .. vim.fn.fnamemodify(path, ":~")
                        .. " asks for "
                        .. M.label(conn)
                        .. "; use :Herdr connect to switch",
                    vim.log.levels.INFO
                )
            end
            return
        end
        M.switch(conn)
    end
    local function connect()
        if c.profile then
            return M.resolve(c.profile, function(conn)
                if type(c.projects_dir) == "string" and c.projects_dir ~= "" then
                    conn.projects_dir = c.projects_dir
                end
                go(conn)
            end)
        end
        go(c)
    end
    if trust == "allowed" then
        return connect()
    end
    if M.active then
        return -- don't interrupt an active connection with a trust prompt
    end
    local what = c.profile and ("profile '" .. c.profile .. "'") or M.label(c)
    -- Defer so the prompt shows after startup UI (e.g. a dashboard) settles.
    vim.defer_fn(function()
        vim.ui.select({ "Trust and connect", "Not now", "Never (deny)" }, {
            prompt = "herdr: " .. vim.fn.fnamemodify(path, ":~") .. " wants to connect to " .. what,
        }, function(choice)
            -- vim.secure.trust writes into stdpath("state"), which may not exist yet.
            if choice == "Trust and connect" or choice == "Never (deny)" then
                vim.fn.mkdir(vim.fn.stdpath("state"), "p")
            end
            if choice == "Trust and connect" then
                M.trust_allow(path)
                connect()
            elseif choice == "Never (deny)" then
                vim.secure.trust({ action = "deny", path = path })
            end
        end)
    end, 200)
end

-- UI ---------------------------------------------------------------------------

local SOURCE_TAG = {
    current = "",
    last = "last used",
    ["local"] = "",
    config = "config",
    saved = "saved",
    herdr = "herdr machine",
}

local function prompt_new(cb)
    local input = require("herdr.ui").input
    input({ prompt = "SSH target (empty for local): " }, function(target)
        if target == nil then
            connected_waiters = {}
            return
        end
        input({ prompt = "Herdr session: ", default = "main" }, function(session)
            if session == nil then
                connected_waiters = {}
                return
            end
            cb(normalize({ remote = vim.trim(target), session = vim.trim(session) }))
        end)
    end)
end

local function offer_save(c)
    require("herdr.ui").input(
        { prompt = "Save as profile (name, empty to skip): ", default = c.remote or "local" },
        function(name)
            if name and vim.trim(name) ~= "" then
                M.save(vim.trim(name), c)
                if M.same(c, M.active) then
                    M.active.name = vim.trim(name)
                end
                vim.notify("herdr: saved profile '" .. vim.trim(name) .. "'")
            end
        end
    )
end

--- `:Herdr connect` with no argument: pick a known connection or add one.
function M.pick()
    M.list(function(list)
        local entries = {}
        for _, c in ipairs(list) do
            entries[#entries + 1] = c
        end
        entries[#entries + 1] = { new = true }
        if M.active then
            entries[#entries + 1] = { disconnect = true }
        end
        vim.ui.select(entries, {
            prompt = "herdr: connect to",
            format_item = function(c)
                if c.new then
                    return "+ New connection…"
                elseif c.disconnect then
                    return "× Disconnect"
                end
                local tag = SOURCE_TAG[c.source] or ""
                local mark = M.same(c, M.active) and "● " or "  "
                return mark .. M.label(c) .. (tag ~= "" and ("  [" .. tag .. "]") or "")
            end,
        }, function(choice)
            if not choice then
                connected_waiters = {}
                return
            end
            if choice.disconnect then
                connected_waiters = {}
                return M.disconnect()
            end
            if choice.new then
                return prompt_new(function(c)
                    M.switch(c)
                    offer_save(c)
                end)
            end
            M.switch(choice)
        end)
    end)
end

return M
