-- Test runner: nvim --headless --noplugin -u tests/init.lua -c "luafile tests/run.lua"
-- Runs tests/test_*.lua (or the files in $TEST_FILES, space-separated) and
-- exits non-zero on failure.

local files = vim.env.TEST_FILES and vim.split(vim.env.TEST_FILES, "%s+", { trimempty = true }) or nil

MiniTest.run({
    collect = {
        find_files = function()
            return files or vim.fn.globpath("tests", "test_*.lua", true, true)
        end,
    },
    execute = {
        reporter = MiniTest.gen_reporter.stdout({ group_depth = 2, quit_on_finish = false }),
    },
})

-- MiniTest runs asynchronously; quit with the right code once it is done.
local timer = assert(vim.uv.new_timer())
timer:start(
    100,
    100,
    vim.schedule_wrap(function()
        if MiniTest.is_executing() then
            return
        end
        timer:stop()
        local failed = 0
        for _, case in ipairs(MiniTest.current.all_cases or {}) do
            if case.exec and #case.exec.fails > 0 then
                failed = failed + 1
            end
        end
        io.write("\n")
        vim.cmd((failed > 0 and "cquit " .. failed) or "qall!")
    end)
)
