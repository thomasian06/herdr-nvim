#!/usr/bin/env bash
# Run the test suite against every locked Neovim x Herdr version
# (tests/deps.lock.json). Releases are downloaded into .tests/ and verified.
#
#   tests/matrix.sh                 full sweep
#   NVIM_VERSIONS="v0.12.5" HERDR_VERSIONS="0.9.0 0.9.3" tests/matrix.sh
set -uo pipefail
cd "$(dirname "$0")/.."

nvim_versions=${NVIM_VERSIONS:-$(nvim -l tests/deps.lua list neovim)}
herdr_versions=${HERDR_VERSIONS:-$(nvim -l tests/deps.lua list herdr)}
results=()
failed=0

for nv in $nvim_versions; do
    nvim_bin=$(nvim -l tests/deps.lua install-nvim "$nv") || exit 1
    for hv in $herdr_versions; do
        herdr_bin=$(nvim -l tests/deps.lua install-herdr "$hv") || exit 1
        log=".tests/logs/nvim-$nv-herdr-$hv.log"
        mkdir -p .tests/logs
        printf 'neovim %-8s herdr %-6s ... ' "$nv" "$hv"
        if HERDR_BIN="$herdr_bin" "$nvim_bin" --headless --noplugin -u tests/init.lua \
            -c "luafile tests/run.lua" >"$log" 2>&1; then
            echo "ok"
            results+=("ok    neovim $nv  herdr $hv")
        else
            echo "FAILED (see $log)"
            results+=("FAIL  neovim $nv  herdr $hv  ($log)")
            failed=$((failed + 1))
        fi
    done
done

echo
printf '%s\n' "${results[@]}"
exit "$failed"
