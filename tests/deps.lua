-- Test dependencies: pinned plugins and a sweep of Neovim / Herdr versions.
--
--   tests/versions.json   what to test against (edited by hand)
--   tests/deps.lock.json  exact plugin commits and release checksums (generated)
--
-- Usage (via the Makefile):
--   nvim -l tests/deps.lua update                 regenerate the lock file
--   nvim -l tests/deps.lua install                install pinned plugins
--   nvim -l tests/deps.lua install-nvim <ver>     download a locked Neovim, print its binary
--   nvim -l tests/deps.lua install-herdr <ver>    download a locked Herdr, print its binary
--   nvim -l tests/deps.lua list <neovim|herdr>    print the versions in the lock
--
-- Everything is downloaded into .tests/ and verified against the lock.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/.tests"
local versions_path = root .. "/tests/versions.json"
local lock_path = root .. "/tests/deps.lock.json"

local function die(msg)
    -- selene: allow(incorrect_standard_library_use)
    io.stderr:write("deps: " .. msg .. "\n")
    os.exit(1)
end

local function run(cmd, opts)
    local res = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
    if res.code ~= 0 then
        die(table.concat(cmd, " ") .. " failed:\n" .. (res.stderr or "") .. (res.stdout or ""))
    end
    return res.stdout or ""
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local data = vim.json.decode(f:read("*a"))
    f:close()
    return data
end

--- Pretty, stable JSON (sorted keys) so lock diffs are readable.
local function encode(v, indent)
    indent = indent or ""
    local next_indent = indent .. "  "
    if type(v) == "table" then
        if vim.islist(v) then
            if #v == 0 then
                return "[]"
            end
            local parts = {}
            for _, x in ipairs(v) do
                parts[#parts + 1] = next_indent .. encode(x, next_indent)
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        end
        local keys = vim.tbl_keys(v)
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = next_indent .. vim.json.encode(k) .. ": " .. encode(v[k], next_indent)
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return vim.json.encode(v)
end

local function sha256_file(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return vim.fn.sha256(data)
end

local function platform()
    local sys = vim.uv.os_uname()
    local os_name = sys.sysname == "Darwin" and "macos" or sys.sysname:lower()
    local arch = (sys.machine == "arm64" or sys.machine == "aarch64") and "aarch64" or sys.machine
    return os_name .. "-" .. arch
end

-- Neovim release assets per platform (names are the same from v0.10.4 on).
local NVIM_ASSET = {
    ["macos-aarch64"] = "nvim-macos-arm64.tar.gz",
    ["macos-x86_64"] = "nvim-macos-x86_64.tar.gz",
    ["linux-x86_64"] = "nvim-linux-x86_64.tar.gz",
    ["linux-aarch64"] = "nvim-linux-arm64.tar.gz",
}

local function download(url, dest)
    vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
    run({ "curl", "-fsSL", "--retry", "3", "-o", dest, url })
end

-- update ------------------------------------------------------------------------

local function update()
    local want = read_json(versions_path) or die("missing " .. versions_path)
    local lock = { plugins = {}, neovim = {}, herdr = {} }

    for name, url in pairs(want.plugins) do
        local out = run({ "git", "ls-remote", url, "HEAD" })
        local commit = out:match("^(%x+)") or die("no HEAD for " .. url)
        lock.plugins[name] = { url = url, commit = commit }
        io.write(("plugin %-12s %s\n"):format(name, commit))
    end

    local manifest = vim.json.decode(run({ "curl", "-fsSL", "https://herdr.dev/latest.json" }))
    for _, v in ipairs(want.herdr) do
        local rel = manifest.releases[v] or die("herdr " .. v .. " not in herdr.dev/latest.json")
        lock.herdr[v] = {}
        for _, p in ipairs(want.platforms) do
            local url, sha = rel.assets[p], rel.sha256 and rel.sha256[p]
            if not (url and sha) then
                die("herdr " .. v .. " has no " .. p .. " asset")
            end
            lock.herdr[v][p] = { url = url, sha256 = sha }
        end
        io.write(("herdr  %-12s %d platforms\n"):format(v, #want.platforms))
    end

    -- Neovim publishes no checksums for these assets: record them on first fetch.
    local old = read_json(lock_path) or {}
    for _, v in ipairs(want.neovim) do
        lock.neovim[v] = {}
        for _, p in ipairs(want.platforms) do
            local asset = NVIM_ASSET[p] or die("unknown platform " .. p)
            local url = ("https://github.com/neovim/neovim/releases/download/%s/%s"):format(v, asset)
            local known = old.neovim and old.neovim[v] and old.neovim[v][p]
            local sha = known and known.url == url and known.sha256
            if not sha then
                local tmp = vim.fn.tempname()
                download(url, tmp)
                sha = sha256_file(tmp)
                os.remove(tmp)
            end
            lock.neovim[v][p] = { url = url, sha256 = sha }
        end
        io.write(("neovim %-12s %d platforms\n"):format(v, #want.platforms))
    end

    local f = assert(io.open(lock_path, "w"))
    f:write(encode(lock) .. "\n")
    f:close()
    io.write("wrote " .. lock_path .. "\n")
end

-- install -------------------------------------------------------------------------

local function lock_or_die()
    return read_json(lock_path) or die("missing " .. lock_path .. "; run `make deps-update`")
end

local function install_plugins()
    local lock = lock_or_die()
    for name, p in pairs(lock.plugins) do
        local dest = dir .. "/deps/" .. name
        local head = vim.uv.fs_stat(dest .. "/.git")
            and vim.trim(vim.system({ "git", "-C", dest, "rev-parse", "HEAD" }, { text = true }):wait().stdout or "")
        if head ~= p.commit then
            vim.fn.delete(dest, "rf")
            vim.fn.mkdir(dest, "p")
            run({ "git", "-C", dest, "init", "-q" })
            run({ "git", "-C", dest, "fetch", "-q", "--depth", "1", p.url, p.commit })
            run({ "git", "-C", dest, "checkout", "-q", "FETCH_HEAD" })
        end
    end
end

local function verified(path, sha)
    return vim.uv.fs_stat(path) and sha256_file(path) == sha
end

local function install_nvim(v)
    local entry = (lock_or_die().neovim[v] or die("neovim " .. v .. " not in lock"))[platform()]
        or die("neovim " .. v .. " not locked for " .. platform())
    local base = dir .. "/nvim/" .. v
    local tarball = base .. "/" .. vim.fn.fnamemodify(entry.url, ":t")
    local bin_glob = base .. "/*/bin/nvim"
    if not verified(tarball, entry.sha256) then
        vim.fn.delete(base, "rf")
        download(entry.url, tarball)
        if not verified(tarball, entry.sha256) then
            die("checksum mismatch for " .. entry.url)
        end
    end
    if vim.fn.glob(bin_glob) == "" then
        run({ "tar", "-xzf", tarball, "-C", base })
        if vim.fn.has("mac") == 1 then
            -- downloaded binaries are quarantined on macOS
            vim.system({ "xattr", "-dr", "com.apple.quarantine", base }):wait()
        end
    end
    io.write(vim.fn.glob(bin_glob) .. "\n")
end

local function install_herdr(v)
    local entry = (lock_or_die().herdr[v] or die("herdr " .. v .. " not in lock"))[platform()]
        or die("herdr " .. v .. " not locked for " .. platform())
    local bin = dir .. "/herdr/" .. v .. "/herdr"
    if not verified(bin, entry.sha256) then
        download(entry.url, bin)
        if not verified(bin, entry.sha256) then
            die("checksum mismatch for " .. entry.url)
        end
        vim.uv.fs_chmod(bin, tonumber("755", 8))
        if vim.fn.has("mac") == 1 then
            vim.system({ "xattr", "-d", "com.apple.quarantine", bin }):wait()
        end
    end
    io.write(bin .. "\n")
end

local function list(kind)
    local versions = vim.tbl_keys(lock_or_die()[kind] or die("unknown kind " .. tostring(kind)))
    table.sort(versions, function(a, b)
        return vim.version.lt(vim.version.parse(a), vim.version.parse(b))
    end)
    io.write(table.concat(versions, " ") .. "\n")
end

local cmd = arg[1]
if cmd == "update" then
    update()
elseif cmd == "install" then
    install_plugins()
elseif cmd == "install-nvim" then
    install_nvim(arg[2] or die("usage: install-nvim <version>"))
elseif cmd == "install-herdr" then
    install_herdr(arg[2] or die("usage: install-herdr <version>"))
elseif cmd == "list" then
    list(arg[2])
else
    die("usage: nvim -l tests/deps.lua <update|install|install-nvim|install-herdr|list>")
end
