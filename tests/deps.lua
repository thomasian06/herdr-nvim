-- Test dependencies: pinned plugins and the Neovim / Herdr releases to test
-- against (the latest of each).
--
--   tests/versions.json   what to test against (edited by hand)
--   tests/deps.lock.json  exact plugin commits and release checksums (generated)
--
-- Usage (via the Makefile):
--   nvim -l tests/deps.lua update                 regenerate the lock file
--   nvim -l tests/deps.lua install                install pinned plugins
--   nvim -l tests/deps.lua install-nvim           download the locked Neovim, print its binary
--   nvim -l tests/deps.lua install-herdr          download the locked Herdr, print its binary
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

-- Git hooks export repository-local variables that override `git -C`.
-- Clear them in this process before touching any dependency repositories.
local git_vars = vim.system({ "git", "rev-parse", "--local-env-vars" }, { text = true }):wait()
if git_vars.code ~= 0 then
    die("could not determine repository-local Git variables: " .. (git_vars.stderr or ""))
end
for name in (git_vars.stdout or ""):gmatch("[^\r\n]+") do
    vim.env[name] = nil
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

-- Neovim release assets per platform.
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
    local lock = { plugins = {}, neovim = { version = want.neovim }, herdr = { version = want.herdr } }

    for name, url in pairs(want.plugins) do
        local out = run({ "git", "ls-remote", url, "HEAD" })
        local commit = out:match("^(%x+)") or die("no HEAD for " .. url)
        lock.plugins[name] = { url = url, commit = commit }
        io.write(("plugin %-12s %s\n"):format(name, commit))
    end

    local manifest = vim.json.decode(run({ "curl", "-fsSL", "https://herdr.dev/latest.json" }))
    local hv = want.herdr
    local rel = manifest.releases[hv] or die("herdr " .. hv .. " not in herdr.dev/latest.json")
    for _, p in ipairs(want.platforms) do
        local url, sha = rel.assets[p], rel.sha256 and rel.sha256[p]
        if not (url and sha) then
            die("herdr " .. hv .. " has no " .. p .. " asset")
        end
        lock.herdr[p] = { url = url, sha256 = sha }
    end
    io.write(("herdr  %-12s %d platforms\n"):format(hv, #want.platforms))

    -- Neovim publishes no checksums for these assets: record them on first fetch.
    local old = read_json(lock_path) or {}
    local nv = want.neovim
    for _, p in ipairs(want.platforms) do
        local asset = NVIM_ASSET[p] or die("unknown platform " .. p)
        local url = ("https://github.com/neovim/neovim/releases/download/%s/%s"):format(nv, asset)
        local known = old.neovim and old.neovim[p]
        local sha = type(known) == "table" and known.url == url and known.sha256
        if not sha then
            local tmp = vim.fn.tempname()
            download(url, tmp)
            sha = sha256_file(tmp)
            os.remove(tmp)
        end
        lock.neovim[p] = { url = url, sha256 = sha }
    end
    io.write(("neovim %-12s %d platforms\n"):format(nv, #want.platforms))

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

--- The locked release of `kind` ("neovim" or "herdr") for this platform.
local function locked(kind)
    local l = lock_or_die()[kind] or die("no " .. kind .. " in the lock; run `make deps-update`")
    local entry = l[platform()] or die(kind .. " " .. tostring(l.version) .. " not locked for " .. platform())
    return l.version, entry
end

local function install_nvim()
    local v, entry = locked("neovim")
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

local function install_herdr()
    local v, entry = locked("herdr")
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

local cmd = arg[1]
if cmd == "update" then
    update()
elseif cmd == "install" then
    install_plugins()
elseif cmd == "install-nvim" then
    install_nvim()
elseif cmd == "install-herdr" then
    install_herdr()
else
    die("usage: nvim -l tests/deps.lua <update|install|install-nvim|install-herdr>")
end
