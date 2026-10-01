# Development tasks. `make check` runs everything CI runs.
#
#   make deps          install pinned test plugins (tests/deps.lock.json)
#   make deps-update   regenerate the lock from tests/versions.json
#   make fmt           format with StyLua
#   make lint          StyLua --check + selene
#   make typecheck     lua-language-server --check on the plugin code
#   make test          unit, UI and integration tests (HERDR_BIN or herdr on PATH)
#   make check         lint + typecheck + test

NVIM ?= nvim
HERDR_BIN ?= $(shell command -v herdr 2>/dev/null)
VIMRUNTIME ?= $(shell $(NVIM) --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q 2>&1)

.PHONY: check deps deps-update fmt lint typecheck test clean

check: lint typecheck test

deps:
	@$(NVIM) -l tests/deps.lua install

deps-update:
	$(NVIM) -l tests/deps.lua update

fmt:
	stylua lua plugin tests

lint:
	stylua --check lua plugin tests
	selene lua plugin tests

typecheck: deps
	@rm -rf .tests/luals
	VIMRUNTIME=$(VIMRUNTIME) lua-language-server --check lua --checklevel=Warning \
		--configpath $(CURDIR)/.luarc.json --logpath $(CURDIR)/.tests/luals
	VIMRUNTIME=$(VIMRUNTIME) lua-language-server --check plugin --checklevel=Warning \
		--configpath $(CURDIR)/.luarc.json --logpath $(CURDIR)/.tests/luals

test: deps
	HERDR_BIN=$(HERDR_BIN) $(NVIM) --headless --noplugin -u tests/init.lua -c "luafile tests/run.lua"

clean:
	rm -rf .tests
