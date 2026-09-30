-- Connections: which Herdr server/session the plugin talks to.
--
-- A connection is { name?, remote?, session }. `remote = nil` means the local
-- Herdr server. One connection is active at a time.
--
-- Where connections come from (shown together in `:Herdr connect`):
--   - local Herdr (when `herdr` is installed)
--   - `profiles` from setup()
--   - Herdr's own saved machines (`herdr machine list --json`)
--   - profiles saved from Neovim (`:Herdr save`), stored with the last-used
--     connection in stdpath("data")/herdr-nvim/connections.json

local config = require("herdr.config")

local M = {}

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
        source = c.source,
    }
end

--- "host", "host:session", "local", "local:session".
function M.parse(target)
    local host, session = target:match("^(.-):([^:@/]+)$")
    host = host or target
    return normalize({ remote = host, session = session })
end

function M.label(c)
    local where = (c.remote or "local") .. ":" .. c.session
    return c.name and c.name ~= where and (c.name .. " (" .. where .. ")") or where
end

function M.same(a, b)
    return a and b and a.remote == b.remote and a.session == b.session
end

---@return table
function M.current()
    return normalize({ name = M._current_name, remote = config.options.remote, session = config.options.session })
end

--- The connection to use at startup: setup()'s remote/session when given,
--- otherwise the last connection used, otherwise local.
function M.initial(user_opts)
    if user_opts and (user_opts.remote ~= nil or user_opts.session ~= nil) then
        return normalize({ remote = user_opts.remote, session = user_opts.session })
    end
    local last = read_store().last
    if last then
        return normalize(last)
    end
    return normalize({})
end

--- Gather known connections asynchronously. cb(list)
function M.list(cb)
    local out, seen = {}, {}
    local function add(c)
        c = normalize(c)
        local key = (c.remote or "") .. "\0" .. c.session
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = c
        end
    end
    local o = config.options
    -- The active connection is always offered, even if it is not a profile.
    add(vim.tbl_extend("force", M.current(), { source = "current" }))
    local has_local = vim.fn.executable(o.herdr_bin) == 1
    if has_local then
        add({ source = "local" })
    end
    for _, p in ipairs(o.profiles or {}) do
        add(vim.tbl_extend("force", p, { source = "config" }))
    end
    for _, p in ipairs(read_store().profiles) do
        add(vim.tbl_extend("force", p, { source = "saved" }))
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
    c = normalize(c or M.current())
    local data = read_store()
    data.profiles = vim.tbl_filter(function(p)
        return p.name ~= name
    end, data.profiles)
    data.profiles[#data.profiles + 1] = { name = name, remote = c.remote, session = c.session }
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
    for _, p in ipairs(config.options.profiles or {}) do
        if p.name then
            names[#names + 1] = p.name
        end
    end
    return names
end

local function remember_last(c)
    local data = read_store()
    data.last = { name = c.name, remote = c.remote, session = c.session }
    write_store(data)
end

--- Switch to a connection: detach and close the old server's terminals,
--- disconnect, then connect to the new one.
function M.switch(c)
    c = normalize(c)
    local state = require("herdr.state")
    if M.same(c, M.current()) and require("herdr.transport").status ~= "failed" then
        M._current_name = c.name or M._current_name
        return state.start()
    end
    if package.loaded["herdr.terminal"] then
        require("herdr.terminal").close_all()
    end
    state.reset()
    require("herdr.transport").shutdown()
    config.options.remote = c.remote
    config.options.session = c.session
    M._current_name = c.name
    remember_last(c)
    state.start()
end

function M.disconnect()
    if package.loaded["herdr.terminal"] then
        require("herdr.terminal").close_all()
    end
    require("herdr.state").reset()
    require("herdr.transport").shutdown()
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

-- UI ---------------------------------------------------------------------------

local SOURCE_TAG = { current = "", ["local"] = "", config = "config", saved = "saved", herdr = "herdr machine" }

local function prompt_new(cb)
    require("herdr.ui").input({ prompt = "SSH target (empty for local): " }, function(target)
        if target == nil then
            return
        end
        require("herdr.ui").input({ prompt = "Herdr session: ", default = "main" }, function(session)
            if session == nil then
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
                M._current_name = vim.trim(name)
                vim.notify("herdr: saved profile '" .. vim.trim(name) .. "'")
            end
        end
    )
end

--- `:Herdr connect` with no argument: pick a known connection or add one.
function M.pick()
    M.list(function(list)
        local current = M.current()
        local entries = {}
        for _, c in ipairs(list) do
            entries[#entries + 1] = c
        end
        entries[#entries + 1] = { new = true }
        vim.ui.select(entries, {
            prompt = "herdr: connect to",
            format_item = function(c)
                if c.new then
                    return "+ New connection…"
                end
                local tag = SOURCE_TAG[c.source] or ""
                local mark = M.same(c, current) and "● " or "  "
                return mark .. M.label(c) .. (tag ~= "" and ("  [" .. tag .. "]") or "")
            end,
        }, function(choice)
            if not choice then
                return
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
