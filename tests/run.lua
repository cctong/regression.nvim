local failures = 0
local tests = {}

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function truthy(value, message)
  if not value then error(message or "expected a truthy value") end
end

require("regression").setup({
  startup = { enabled = false },
  health = { enabled = false },
})

test("plugin commands are registered", function()
  truthy(vim.fn.exists(":NvimBaseline") == 2)
  truthy(vim.fn.exists(":NvimRegression") == 2)
  truthy(vim.fn.exists(":NvimBisect") == 2)
end)

test("comparison detects behavioral regressions and revision changes", function()
  local baseline = {
    startup_ms = 40,
    errors = {},
    lsp = { lua_ls = { initialized = true, stopped = false } },
    health = { failures = 0, warnings = 0 },
    plugins = { alpha = { revision = "aaaaaaaaaa", dir = "/tmp/alpha" } },
  }
  local current = {
    startup_ms = 80,
    errors = { "Error: broken" },
    lsp = {},
    health = { failures = 1, warnings = 2 },
    plugins = { alpha = { revision = "bbbbbbbbbb", dir = "/tmp/alpha" } },
  }
  local result = require("regression.compare").snapshots(baseline, current)
  truthy(result.has_regressions)
  equal(5, #result.regressions)
  equal(1, #result.plugin_changes)
  equal("alpha", result.plugin_changes[1].name)
end)

test("existing baseline errors are not regressions", function()
  local snapshot = { errors = { "Error: known" }, lsp = {}, plugins = {} }
  local result = require("regression.compare").snapshots(snapshot, vim.deepcopy(snapshot))
  equal(false, result.has_regressions)
end)

test("store round-trips a snapshot", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    profile = "test",
    startup = { enabled = false },
    health = { enabled = false },
  })
  local store = require("regression.store")
  local snapshot = { schema_version = 1, errors = {}, plugins = { one = { revision = "abc" } } }
  local path = assert(store.save(snapshot))
  truthy(vim.uv.fs_stat(path) ~= nil)
  equal(snapshot, assert(store.load()))
  vim.fn.delete(directory, "rf")
end)

test("bisect set search locates the reverted group that heals", function()
  local candidates = { "alpha", "bravo", "charlie", "delta", "echo" }
  local culprit = require("regression.bisect").locate(candidates, function(group)
    return vim.tbl_contains(group, "charlie")
  end)
  equal("charlie", culprit)
end)

for _, item in ipairs(tests) do
  local ok, err = xpcall(item.fn, debug.traceback)
  if ok then
    print("ok - " .. item.name)
  else
    failures = failures + 1
    print("not ok - " .. item.name .. "\n" .. err)
  end
end

if failures > 0 then
  vim.cmd("cquit " .. failures)
end
print(string.format("%d tests passed", #tests))
vim.cmd("qa!")

