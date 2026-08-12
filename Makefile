.PHONY: test

test:
	XDG_STATE_HOME=/tmp/regression.nvim-test-state XDG_DATA_HOME=/tmp/regression.nvim-test-data nvim --headless -i NONE -u tests/minimal_init.lua -l tests/run.lua
