-- Live smoke test against a running Herdr server (read-only).
-- Usage: HERDR_REMOTE=devbox nvim --headless -u NONE -l tests/smoke_api.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local remote = os.getenv("HERDR_REMOTE")
require("herdr.config").setup({
    remote = remote ~= "" and remote or nil,
    session = os.getenv("HERDR_SESSION") or "main",
})
local api = require("herdr.api")
local transport = require("herdr.transport")

local done, failed = false, false
local function out(...)
    io.stdout:write(table.concat(vim.tbl_map(tostring, { ... }), " ") .. "\n")
end

api.request("ping", nil, function(err, res)
    if err then
        failed = true
        done = true
        return out("PING FAILED", err)
    end
    out("ping ok:", res.version, "protocol", res.protocol)
    api.request("session.snapshot", nil, function(serr, snap)
        if serr then
            failed = true
            done = true
            return out("SNAPSHOT FAILED", serr)
        end
        local s = snap.snapshot
        out("snapshot ok:", #s.workspaces, "workspaces,", #s.tabs, "tabs,", #s.panes, "panes")
        local subs = {
            { type = "pane.focused" },
            { type = "tab.focused" },
            { type = "workspace.focused" },
            { type = "pane.updated" },
        }
        for _, p in ipairs(s.panes) do
            subs[#subs + 1] = { type = "pane.agent_status_changed", pane_id = p.pane_id }
        end
        local wait_ms = tonumber(os.getenv("HERDR_EVENT_WAIT_MS") or "0")
        if wait_ms == 0 then
            done = true
            return
        end
        local h
        h = api.subscribe(subs, function(ev, data)
            out("event:", ev, vim.json.encode(data):sub(1, 160))
        end, function(cerr)
            out("subscription closed:", cerr or "ok")
        end)
        vim.defer_fn(function()
            h.close()
            done = true
        end, wait_ms)
    end)
end)

vim.wait(120000, function()
    return done
end, 50)
out("shutting down")
transport.shutdown()
out("shutdown done")
os.exit(failed and 1 or 0)
