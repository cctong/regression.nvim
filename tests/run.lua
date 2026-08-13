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

local function git_in(dir, args)
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

local function make_repo(commits)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git_in(dir, { "init", "-q" })
  local shas = {}
  for index = 1, commits or 4 do
    vim.fn.writefile({ "v" .. index }, dir .. "/file.txt")
    git_in(dir, { "add", "file.txt" })
    git_in(dir, { "commit", "-q", "-m", "commit " .. index })
    shas[index] = git_in(dir, { "rev-parse", "HEAD" })
  end
  return dir, shas
end

test("plugin commands are registered", function()
  truthy(vim.fn.exists(":NvimBaseline") == 2)
  truthy(vim.fn.exists(":NvimRegression") == 2)
  truthy(vim.fn.exists(":NvimHealth") == 2)
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

test("comparison reports config file changes", function()
  local baseline = {
    errors = {},
    lsp = {},
    plugins = {},
    config_files = {
      ["init.lua"] = "aaa",
      ["lua/old.lua"] = "bbb",
    },
  }
  local current = {
    errors = {},
    lsp = {},
    plugins = {},
    config_files = {
      ["init.lua"] = "ccc",
      ["lua/new.lua"] = "ddd",
    },
  }
  local result = require("regression.compare").snapshots(baseline, current)
  equal(false, result.has_regressions)
  equal({
    "config: init.lua changed",
    "config added: lua/new.lua",
    "config removed: lua/old.lua",
  }, result.changes)
end)

test("collector hashes tracked config files", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/lua", "p")
  vim.fn.writefile({ "vim.g.foo = 1" }, root .. "/init.lua")
  vim.fn.writefile({ "return {}" }, root .. "/lua/plugins.lua")
  vim.fn.writefile({ "ignore" }, root .. "/notes.txt")
  local hashes = require("regression.collector").hash_files(root)
  equal(vim.fn.sha256("vim.g.foo = 1\n"), hashes["init.lua"])
  equal(vim.fn.sha256("return {}\n"), hashes["lua/plugins.lua"])
  equal(nil, hashes["notes.txt"])
  vim.fn.delete(root, "rf")
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
  local dir, shas = make_repo(4)
  local adapter = require("regression.adapters.lazy")
  local plugin = { dir = dir }
  local between = assert(adapter.revisions_between(plugin, shas[1], shas[4]))
  equal({ shas[2], shas[3], shas[4] }, between)
  equal("commit 3", adapter.commit_subject(plugin, shas[3]))
  vim.fn.delete(dir, "rf")
end)

test("git worktree add leaves the original checkout unchanged", function()
  local dir, shas = make_repo(3)
  local git = require("regression.git")
  local worktree = vim.fn.tempname() .. "/plugin-wt"
  assert(git.worktree_add({ dir = dir }, shas[1], worktree))
  equal(shas[1], git.revision(worktree))
  equal(shas[3], git.revision(dir))
  equal("v1", vim.fn.readfile(worktree .. "/file.txt")[1])
  equal("v3", vim.fn.readfile(dir .. "/file.txt")[1])
  assert(git.worktree_remove({ dir = dir }, worktree))
  truthy(vim.uv.fs_stat(worktree) == nil)
  equal(shas[3], git.revision(dir))
  vim.fn.delete(dir, "rf")
end)

test("shadow checkout uses a worktree instead of the live plugin dir", function()
  local real_data = vim.fn.tempname()
  local dir, shas = make_repo(3)
  local plugin_dir = real_data .. "/lazy/alpha"
  vim.fn.mkdir(real_data .. "/lazy", "p")
  vim.fn.rename(dir, plugin_dir)
  vim.fn.writefile({ "keep" }, real_data .. "/other.txt")
  local shadow_mod = require("regression.shadow")
  local shadow = shadow_mod.create(real_data)
  local plugin = { dir = plugin_dir }
  assert(shadow_mod.use_revision(shadow, plugin, shas[1]))
  equal(shas[1], require("regression.git").revision(shadow_mod.path(shadow, plugin_dir)))
  equal(shas[3], require("regression.git").revision(plugin_dir))
  equal("v3", vim.fn.readfile(plugin_dir .. "/file.txt")[1])
  assert(shadow_mod.use_live(shadow, plugin))
  equal(shas[3], require("regression.git").revision(plugin_dir))
  shadow_mod.destroy(shadow)
  equal(shas[3], require("regression.git").revision(plugin_dir))
  vim.fn.delete(real_data, "rf")
end)

test("pack adapter is unavailable without vim.pack", function()
  local previous = rawget(vim, "pack")
  rawset(vim, "pack", {})
  equal(false, require("regression.adapters.pack").available())
  rawset(vim, "pack", previous)
end)

test("pack adapter maps vim.pack plugins", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  local previous = rawget(vim, "pack")
  rawset(vim, "pack", {
    get = function()
      return {
        {
          path = dir,
          rev = "abc123def",
          spec = { name = "example", src = "https://example.com/example.git" },
        },
      }
    end,
  })
  local adapter = require("regression.adapters.pack")
  truthy(adapter.available())
  local plugins = adapter.plugins()
  equal("example", plugins.example.name)
  equal(vim.fs.normalize(dir), plugins.example.dir)
  equal("https://example.com/example.git", plugins.example.url)
  equal("abc123def", plugins.example.revision)
  rawset(vim, "pack", previous)
  vim.fn.delete(dir, "rf")
end)

test("health reports adapter problems", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  local found
  for _, item in ipairs(require("regression.health").check()) do
    if item.level == "error" and item.text:match("lazy%.nvim is not loaded") then
      found = item
      break
    end
  end
  truthy(found, "expected an adapter error about lazy.nvim")
  vim.fn.delete(directory, "rf")
end)

test("health flags a missing baseline", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  local found
  for _, item in ipairs(require("regression.health").check()) do
    if item.level == "warn" and item.text:match("no baseline yet") then
      found = item
      break
    end
  end
  truthy(found, "expected a missing-baseline warning")
  vim.fn.delete(directory, "rf")
end)

test("health flags an invalid baseline", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile({ "not json" }, directory .. "/default.json")
  local found
  for _, item in ipairs(require("regression.health").check()) do
    if item.level == "error" and item.text:match("baseline is invalid") then
      found = item
      break
    end
  end
  truthy(found, "expected an invalid-baseline error")
  vim.fn.delete(directory, "rf")
end)

test("health accepts a valid baseline", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  require("regression.store").save({ plugins = { alpha = {} }, captured_at = "2026-01-01T00:00:00Z" })
  local found
  for _, item in ipairs(require("regression.health").check()) do
    if item.text:match("baseline") then
      if item.level == "warn" or item.level == "error" then
        error("unexpected baseline problem: " .. vim.inspect(item))
      end
      if item.level == "info" and item.text:match("baseline is valid") then
        found = item
      end
    end
  end
  truthy(found, "expected a valid-baseline info line")
  vim.fn.delete(directory, "rf")
end)

test("health run opens a scratch buffer", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  require("regression.health").run()
  truthy(vim.api.nvim_buf_get_name(0):match("regression://report$"))
  equal("regression.nvim health", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
  vim.fn.delete(directory, "rf")
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

