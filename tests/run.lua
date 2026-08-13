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

test("comparison reports a replaced health error with the same count", function()
  local baseline = {
    errors = {},
    lsp = {},
    plugins = {},
    health = {
      failures = 1,
      warnings = 1,
      failure_messages = { "- ERROR: old provider missing" },
      warning_messages = { "- WARNING: parser outdated" },
    },
  }
  local current = {
    errors = {},
    lsp = {},
    plugins = {},
    health = {
      failures = 1,
      warnings = 1,
      failure_messages = { "- ERROR: treesitter highlight failed" },
      warning_messages = { "- WARNING: parser outdated" },
    },
  }
  local result = require("regression.compare").snapshots(baseline, current)
  truthy(result.has_regressions)
  equal(1, #result.regressions)
  equal("health", result.regressions[1].kind)
  equal("- ERROR: treesitter highlight failed", result.regressions[1].message)
end)

test("comparison ignores health messages already present in the baseline", function()
  local snapshot = {
    errors = {},
    lsp = {},
    plugins = {},
    health = {
      failures = 1,
      warnings = 1,
      failure_messages = { "- ERROR: old provider missing" },
      warning_messages = { "- WARNING: parser outdated" },
    },
  }
  local result = require("regression.compare").snapshots(snapshot, vim.deepcopy(snapshot))
  equal(false, result.has_regressions)
end)

test("comparison reports a neovim version change", function()
  local baseline = { nvim_version = "0.10.0", errors = {}, lsp = {}, plugins = {} }
  local current = { nvim_version = "0.11.0", errors = {}, lsp = {}, plugins = {} }
  local result = require("regression.compare").snapshots(baseline, current)
  equal(false, result.has_regressions)
  equal({ "neovim: 0.10.0 -> 0.11.0" }, result.changes)
end)

test("comparison reports a new adapter failure as a regression", function()
  local baseline = { errors = {}, lsp = {}, plugins = {} }
  local current = {
    errors = {},
    lsp = {},
    plugins = {},
    adapter_error = "lazy.nvim is not loaded; call require('lazy').setup() before using regression.nvim",
  }
  local result = require("regression.compare").snapshots(baseline, current)
  truthy(result.has_regressions)
  equal(1, #result.regressions)
  equal("adapter", result.regressions[1].kind)
end)

test("comparison ignores an adapter failure already present in the baseline", function()
  local snapshot = {
    errors = {},
    lsp = {},
    plugins = {},
    adapter_error = "lazy.nvim is not loaded",
  }
  local result = require("regression.compare").snapshots(snapshot, vim.deepcopy(snapshot))
  equal(false, result.has_regressions)
end)

test("report opens a scratch buffer with the comparison", function()
  local comparison = {
    has_regressions = true,
    regressions = { { kind = "error", message = "Error: broken" } },
    changes = { "neovim: 0.10.0 -> 0.11.0" },
    plugin_changes = {},
  }
  local report = require("regression.report")
  local buf = report.show(comparison)
  truthy(vim.api.nvim_buf_is_valid(buf))
  equal("nofile", vim.bo[buf].buftype)
  equal(report.format(comparison), table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
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

test("commit search finds the first bad revision", function()
  local commits = { "c1", "c2", "c3", "c4", "c5" }
  local first = require("regression.bisect").first_bad(commits, function(commit)
    return commit >= "c4"
  end)
  equal("c4", first)
end)

test("commit search returns a single revision without probing", function()
  local probed = false
  local first = require("regression.bisect").first_bad({ "only" }, function()
    probed = true
    return true
  end)
  equal("only", first)
  equal(false, probed)
end)

test("lazy adapter lists commits between two revisions", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(args)
    local argv = {
      "git",
      "-C",
      dir,
      "-c",
      "user.name=regression",
      "-c",
      "user.email=regression@example.com",
      "-c",
      "commit.gpgsign=false",
    }
    vim.list_extend(argv, args)
    local result = require("regression.util").system(argv)
    if result.code ~= 0 then
      error(result.stderr ~= "" and result.stderr or result.stdout)
    end
    return require("regression.util").trim(result.stdout)
  end
  git({ "init", "-q" })
  local shas = {}
  for index = 1, 4 do
    vim.fn.writefile({ "v" .. index }, dir .. "/file.txt")
    git({ "add", "file.txt" })
    git({ "commit", "-q", "-m", "commit " .. index })
    shas[index] = git({ "rev-parse", "HEAD" })
  end
  local adapter = require("regression.adapters.lazy")
  local plugin = { dir = dir }
  local between = assert(adapter.revisions_between(plugin, shas[1], shas[4]))
  equal({ shas[2], shas[3], shas[4] }, between)
  equal("commit 3", adapter.commit_subject(plugin, shas[3]))
  vim.fn.delete(dir, "rf")
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

