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

local function valid_snapshot(overrides)
  local snapshot = {
    schema_version = 1,
    captured_at = "2026-01-01T00:00:00Z",
    nvim_version = "0.10.0",
    adapter = "lazy",
    errors = {},
    lsp = {},
    plugins = {},
  }
  if overrides then
    snapshot = vim.tbl_deep_extend("force", snapshot, overrides)
  end
  return snapshot
end

require("regression").setup({
  startup = { enabled = false },
  health = { enabled = false },
})

local function write_lines(path, chunks)
  vim.fn.writefile(vim.split(table.concat(chunks, "\n"), "\n", { plain = true }), path)
end

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
  local snapshot = valid_snapshot({ plugins = { one = { revision = "abc" } } })
  local path = assert(store.save(snapshot))
  truthy(vim.uv.fs_stat(path) ~= nil)
  equal(snapshot, assert(store.load()))
  vim.fn.delete(directory, "rf")
end)

test("collector emits a valid snapshot", function()
  local snapshot = require("regression.collector").collect()
  local ok, err = require("regression.snapshot").validate(snapshot)
  truthy(ok, "collector snapshot failed validation: " .. tostring(err))
end)

test("store loads an initial schema baseline", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    profile = "test",
    startup = { enabled = false },
    health = { enabled = false },
  })
  local store = require("regression.store")
  vim.fn.mkdir(directory, "p")
  local fixture = valid_snapshot()
  vim.fn.writefile({ vim.json.encode(fixture) }, store.path())
  equal(fixture, assert(store.load()))
  vim.fn.delete(directory, "rf")
end)

test("store rejects non-object baselines", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    profile = "test",
    startup = { enabled = false },
    health = { enabled = false },
  })
  local store = require("regression.store")
  vim.fn.mkdir(directory, "p")
  for _, content in ipairs({ "null", "[]", '"not an object"' }) do
    vim.fn.writefile({ content }, store.path())
    local loaded, err = store.load()
    equal(nil, loaded, "expected nil baseline for " .. content)
    equal("baseline must be a JSON object", err)
  end
  vim.fn.delete(directory, "rf")
end)

test("store rejects unsupported baseline schemas", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    profile = "test",
    startup = { enabled = false },
    health = { enabled = false },
  })
  local store = require("regression.store")
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile({ vim.json.encode(valid_snapshot({ schema_version = 2 })) }, store.path())
  local loaded, err = store.load()
  equal(nil, loaded)
  equal("unsupported baseline schema version 2 (supported: 1)", err)
  vim.fn.delete(directory, "rf")
end)

test("store rejects malformed nested baseline fields", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    profile = "test",
    startup = { enabled = false },
    health = { enabled = false },
  })
  local store = require("regression.store")
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile({ vim.json.encode(valid_snapshot({ plugins = { alpha = "not an object" } })) }, store.path())
  local loaded, err = store.load()
  equal(nil, loaded)
  equal('baseline field "plugins.alpha" must be an object', err)
  vim.fn.delete(directory, "rf")
end)

test("store rejects invalid snapshots before saving", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    profile = "test",
    startup = { enabled = false },
    health = { enabled = false },
  })
  local store = require("regression.store")
  local path, err = store.save(valid_snapshot({ plugins = { alpha = "not an object" } }))
  equal(nil, path)
  equal('baseline field "plugins.alpha" must be an object', err)
  equal(nil, vim.uv.fs_stat(directory))
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

test("shadow use_live accepts a symlinked data alias before any revision", function()
  local actual = vim.fn.tempname() .. "-actual"
  local repo = actual .. "/lazy/alpha"
  vim.fn.mkdir(repo, "p")
  git_in(repo, { "init", "-q" })
  vim.fn.writefile({ "keep" }, repo .. "/file.txt")
  git_in(repo, { "add", "file.txt" })
  git_in(repo, { "commit", "-q", "-m", "keep" })
  local sha = git_in(repo, { "rev-parse", "HEAD" })
  local link_dir = vim.fn.tempname() .. "-linkdir"
  vim.fn.mkdir(link_dir, "p")
  local alias = link_dir .. "/data"
  truthy(vim.uv.fs_symlink(actual, alias))
  local plugin_dir = vim.fs.normalize(alias) .. "/lazy/alpha"
  local shadow_mod = require("regression.shadow")
  local shadow = shadow_mod.create(alias)
  local ok, err = shadow_mod.use_live(shadow, { dir = plugin_dir })
  local readlink = vim.uv.fs_readlink(alias)
  local head = require("regression.git").revision(repo)
  local line = vim.fn.readfile(repo .. "/file.txt")[1]
  shadow_mod.destroy(shadow)
  vim.fn.delete(actual, "rf")
  vim.fn.delete(link_dir, "rf")
  truthy(ok, err)
  equal(sha, head)
  equal("keep", line)
  equal(actual, readlink)
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
    if item.level == "error"
      and item.text:match("^baseline is invalid: invalid JSON:")
      and item.text:match("; update regression%.nvim or use :NvimBaseline! to replace it$")
    then
      found = item
      break
    end
  end
  truthy(found, "expected an invalid-baseline error with recovery action")
  vim.fn.delete(directory, "rf")
end)

test("health flags an unsupported baseline schema", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile({ vim.json.encode(valid_snapshot({ schema_version = 2 })) }, directory .. "/default.json")
  local baseline_items = {}
  for _, item in ipairs(require("regression.health").check()) do
    if item.text:match("baseline") then
      baseline_items[#baseline_items + 1] = item
    end
  end
  equal(1, #baseline_items)
  equal("error", baseline_items[1].level)
  equal(
    "baseline is invalid: unsupported baseline schema version 2 (supported: 1); update regression.nvim or use :NvimBaseline! to replace it",
    baseline_items[1].text
  )
  vim.fn.delete(directory, "rf")
end)

test("health accepts a valid baseline", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  assert(require("regression.store").save(valid_snapshot({ plugins = { alpha = {} } })))
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

test("regression and bisect stop before collecting with an invalid baseline", function()
  local directory = vim.fn.tempname()
  require("regression").setup({
    storage_dir = directory,
    startup = { enabled = false },
    health = { enabled = false },
  })
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile({ vim.json.encode(valid_snapshot({ schema_version = 2 })) }, directory .. "/default.json")

  local real_collector = package.loaded["regression.collector"]
  local real_notify = vim.notify
  local messages = {}
  package.loaded["regression.collector"] = { collect = function() error("collector stub reached") end }
  vim.notify = function(message, level, opts)
    messages[#messages + 1] = tostring(message)
  end

  local ok, failure = xpcall(function()
    local regression = require("regression")
    equal(nil, regression.regression())
    equal(nil, regression.bisect())
  end, debug.traceback)

  vim.notify = real_notify
  package.loaded["regression.collector"] = real_collector

  if not ok then
    error(failure)
  end
  truthy(#messages >= 2, "expected a notification from regression and one from bisect")
  for _, message in ipairs(messages) do
    truthy(message:match("No readable baseline%. Update regression%.nvim or use :NvimBaseline! to replace it%."))
    truthy(message:match("unsupported baseline schema version 2 %(supported: 1%)"))
  end
  vim.fn.delete(directory, "rf")
end)

local function worktree_paths(dir)
  local paths = {}
  for _, line in ipairs(vim.split(git_in(dir, { "worktree", "list", "--porcelain" }), "\n", { plain = true })) do
    local path = line:match("^worktree%s+(.*)$")
    if path then
      paths[#paths + 1] = vim.fs.normalize(vim.fn.resolve(path))
    end
  end
  return paths
end

local function assert_live_repo(dir, sha, relative, line)
  equal(sha, require("regression.git").revision(dir))
  equal(line, vim.fn.readfile(dir .. "/" .. relative)[1])
  equal({ vim.fs.normalize(vim.fn.resolve(dir)) }, worktree_paths(dir))
  local extra = dir .. "/.git/worktrees"
  if vim.uv.fs_stat(extra) then
    local handle = vim.uv.fs_scandir(extra)
    local name = handle and vim.uv.fs_scandir_next(handle) or nil
    equal(nil, name)
  end
end

local function install_fake_adapter()
  local git = require("regression.git")
  package.loaded["regression.adapters.fake"] = {
    name = "fake",
    available = function() return true end,
    is_dirty = git.is_dirty,
    has_revision = git.has_revision,
    checkout = git.checkout,
    revisions_between = git.revisions_between,
    commit_subject = git.commit_subject,
  }
end

local function repo_with_states(dir, states)
  vim.fn.mkdir(dir .. "/lua", "p")
  git_in(dir, { "init", "-q" })
  local shas = {}
  for index, state in ipairs(states) do
    vim.fn.writefile({
      "return " .. string.format("%q", state),
      "-- revision " .. index,
    }, dir .. "/lua/marker.lua")
    git_in(dir, { "add", "lua/marker.lua" })
    git_in(dir, { "commit", "-q", "-m", "commit " .. index })
    shas[index] = git_in(dir, { "rev-parse", "HEAD" })
  end
  return shas
end

-- Parent snapshots keep identical standard signals. The child init only exposes
-- plugin checkouts that landed in the shadowed data directory.
local function with_custom_bisect(opts, fn)
  local id = vim.fn.fnamemodify(vim.fn.tempname(), ":t")
  local data = vim.fs.normalize(vim.fn.stdpath("data"))
  local culprit_name = "a-culprit-" .. id
  local decoy_name = "z-decoy-" .. id
  local culprit_dir = data .. "/lazy/" .. culprit_name
  local decoy_dir = data .. "/lazy/" .. decoy_name
  local config_home = vim.fn.tempname() .. "-config"
  local sample = vim.fn.tempname() .. "-sample.lua"
  local previous_config = vim.env.XDG_CONFIG_HOME
  local previous_swap = vim.o.swapfile
  local previous_buf = vim.api.nvim_get_current_buf()
  local include_decoy = opts.decoy ~= false
  local shas, decoy_shas
  local shadow_mod = require("regression.shadow")
  local real_create = shadow_mod.create
  local homes = {}
  shadow_mod.create = function(...)
    local created = real_create(...)
    homes[#homes + 1] = created.home
    return created
  end

  local function remove_repo(dir)
    if not vim.uv.fs_stat(dir) then
      return
    end
    pcall(git_in, dir, { "worktree", "prune" })
    vim.fn.delete(dir, "rf")
  end

  local function cleanup()
    shadow_mod.create = real_create
    vim.env.XDG_CONFIG_HOME = previous_config
    vim.o.swapfile = previous_swap
    package.loaded["regression.adapters.fake"] = nil
    pcall(function()
      if vim.api.nvim_buf_is_valid(previous_buf) then
        vim.api.nvim_set_current_buf(previous_buf)
      end
      local sample_buf = vim.fn.bufnr(sample)
      if sample_buf ~= -1 then
        vim.cmd("bwipeout! " .. sample_buf)
      end
    end)
    vim.fn.delete(config_home, "rf")
    vim.fn.delete(sample)
    remove_repo(culprit_dir)
    if include_decoy then
      remove_repo(decoy_dir)
    end
    require("regression").setup({
      startup = { enabled = false },
      health = { enabled = false },
    })
  end

  local ok, err = xpcall(function()
    vim.fn.mkdir(data .. "/lazy", "p")
    shas = repo_with_states(culprit_dir, opts.states)
    if include_decoy then
      vim.fn.mkdir(decoy_dir, "p")
      git_in(decoy_dir, { "init", "-q" })
      decoy_shas = {}
      for index = 1, 2 do
        vim.fn.writefile({ "v" .. index }, decoy_dir .. "/file.txt")
        git_in(decoy_dir, { "add", "file.txt" })
        git_in(decoy_dir, { "commit", "-q", "-m", "decoy " .. index })
        decoy_shas[index] = git_in(decoy_dir, { "rev-parse", "HEAD" })
      end
    end
    culprit_dir = vim.fs.normalize(culprit_dir)
    decoy_dir = vim.fs.normalize(decoy_dir)

    vim.fn.mkdir(config_home .. "/nvim/lua/regression_checks", "p")
    vim.o.swapfile = false
    vim.fn.writefile({ "return 'sample'" }, sample)
    vim.cmd.edit(vim.fn.fnameescape(sample))
    local opened = vim.api.nvim_buf_get_name(0)
    local rtp_names = { culprit_name }
    if include_decoy then
      rtp_names[#rtp_names + 1] = decoy_name
    end
    local init = {
      "vim.opt.swapfile = false",
      "vim.opt.shortmess:append('A')",
    }
    if opts.init_prelude then
      init[#init + 1] = opts.init_prelude
    end
    init[#init + 1] = "local names = " .. vim.inspect(rtp_names)
    init[#init + 1] = [[
local lazy = vim.fn.stdpath("data") .. "/lazy"
for _, name in ipairs(names) do
  local path = lazy .. "/" .. name
  if vim.uv.fs_stat(path) then
    vim.opt.runtimepath:prepend(path)
  end
end
]]
    write_lines(config_home .. "/nvim/init.lua", init)
    write_lines(config_home .. "/nvim/lua/regression_checks/behavior.lua", { string.format([[
return function()
  if vim.api.nvim_buf_get_name(0) ~= %q then
    return false, "probe did not open the file"
  end
  local state = require("marker")
  if state == "throw" then
    error("intermediate failure", 0)
  end
  if state == "bad" then
    return false, "marker regressed"
  end
  return true
end
]], opened) })

    install_fake_adapter()
    vim.env.XDG_CONFIG_HOME = config_home
    require("regression").setup({
      startup = { enabled = false },
      health = { enabled = false },
      bisect = {
        test = "regression_checks.behavior",
        timeout_ms = opts.timeout_ms or 60000,
        settle_ms = 0,
      },
    })

    local function plugin_spec(name, dir, revision)
      return {
        name = name,
        dir = dir,
        revision = revision,
        head_ref = require("regression.git").head_ref(dir),
      }
    end
    local function snapshot(plugins)
      return valid_snapshot({
        adapter = "fake",
        startup_ms = 10,
        errors = {},
        lsp = {},
        health = {
          failures = 0,
          warnings = 0,
          command_ok = true,
          failure_messages = {},
          warning_messages = {},
        },
        config_files = { ["init.lua"] = "same" },
        plugins = plugins,
      })
    end
    local baseline_plugins = {
      [culprit_name] = plugin_spec(culprit_name, culprit_dir, shas[1]),
    }
    local current_plugins = {
      [culprit_name] = plugin_spec(culprit_name, culprit_dir, shas[#shas]),
    }
    if include_decoy then
      baseline_plugins[decoy_name] = plugin_spec(decoy_name, decoy_dir, decoy_shas[1])
      current_plugins[decoy_name] = plugin_spec(decoy_name, decoy_dir, decoy_shas[2])
    end
    local baseline = snapshot(baseline_plugins)
    local current = snapshot(current_plugins)
    local compared = require("regression.compare").snapshots(baseline, current)
    equal(false, compared.has_regressions)
    truthy(#compared.plugin_changes > 0)
    fn({
      shas = shas,
      culprit_name = culprit_name,
      culprit_dir = culprit_dir,
      decoy_dir = decoy_dir,
      decoy_shas = decoy_shas,
      baseline = baseline,
      current = current,
    })
    for _, home in ipairs(homes) do
      truthy(vim.uv.fs_stat(home) == nil, "shadow home remains: " .. home)
    end
  end, debug.traceback)
  cleanup()
  if not ok then
    error(err)
  end
end

test("custom bisect finds the first bad commit and restores the live checkout", function()
  with_custom_bisect({
    states = { "healthy", "healthy", "bad", "bad", "bad" },
  }, function(ctx)
    local progress = {}
    local culprit, err = require("regression.bisect").run(ctx.baseline, ctx.current, function(message)
      progress[#progress + 1] = message
    end)
    if not culprit then
      error(err)
    end
    equal(ctx.culprit_name, culprit.name)
    equal(ctx.shas[1], culprit.old_revision)
    equal(ctx.shas[5], culprit.new_revision)
    equal(ctx.shas[3], culprit.first_bad_revision)
    equal("commit 3", culprit.first_bad_subject)
    truthy(vim.tbl_contains(progress, "Reproduced: marker regressed"))
    assert_live_repo(ctx.culprit_dir, ctx.shas[5], "lua/marker.lua", 'return "bad"')
    assert_live_repo(ctx.decoy_dir, ctx.decoy_shas[2], "file.txt", "v2")
  end)
end)

test("custom bisect stops when an intermediate commit throws and restores the checkout", function()
  with_custom_bisect({
    states = { "healthy", "healthy", "throw", "bad", "bad" },
  }, function(ctx)
    local culprit, err = require("regression.bisect").run(ctx.baseline, ctx.current)
    equal(nil, culprit)
    truthy(type(err) == "string" and err:match("bisect test failed: intermediate failure$"), err)
    assert_live_repo(ctx.culprit_dir, ctx.shas[5], "lua/marker.lua", 'return "bad"')
    assert_live_repo(ctx.decoy_dir, ctx.decoy_shas[2], "file.txt", "v2")
  end)
end)

local function probe_payload(test_name, module_lines)
  local root = vim.fn.tempname()
  local output = vim.fn.tempname()
  local saved_rtp = vim.o.runtimepath
  local env_keys = {
    "REGRESSION_PROBE_OUTPUT",
    "REGRESSION_PROBE_TEST",
    "REGRESSION_PROBE_FILE",
    "REGRESSION_PROBE_SETTLE_MS",
    "REGRESSION_EXPECTED_LSP",
  }
  local saved = {}
  for _, key in ipairs(env_keys) do
    saved[key] = vim.env[key]
  end
  if module_lines then
    local path = root .. "/lua/" .. test_name:gsub("%.", "/") .. ".lua"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    write_lines(path, module_lines)
    vim.opt.runtimepath:prepend(root)
    package.loaded[test_name] = nil
  end
  vim.env.REGRESSION_PROBE_OUTPUT = output
  vim.env.REGRESSION_PROBE_FILE = ""
  vim.env.REGRESSION_PROBE_SETTLE_MS = "0"
  vim.env.REGRESSION_EXPECTED_LSP = "[]"
  vim.env.REGRESSION_PROBE_TEST = test_name or ""
  local ok, err = xpcall(function()
    require("regression.probe").run()
  end, debug.traceback)
  local raw
  if ok then
    local fd = io.open(output, "r")
    raw = fd and fd:read("*a") or ""
    if fd then
      fd:close()
    end
  end
  vim.o.runtimepath = saved_rtp
  if test_name and test_name ~= "" then
    package.loaded[test_name] = nil
  end
  for _, key in ipairs(env_keys) do
    vim.env[key] = saved[key]
  end
  vim.fn.delete(root, "rf")
  os.remove(output)
  if not ok then
    error(err)
  end
  return vim.json.decode(raw)
end

test("probe custom check verdicts and the default snapshot payload", function()
  require("regression").setup({
    startup = { enabled = false },
    health = { enabled = false },
  })
  equal({ status = "healthy" }, probe_payload("regression_checks.healthy", {
    "return function() return true end",
  }))
  equal({ status = "healthy" }, probe_payload("regression_checks.true_extra", {
    'return function() return true, "ignored" end',
  }))
  equal({ status = "reproduced" }, probe_payload("regression_checks.false_only", {
    "return function() return false end",
  }))
  equal({ status = "reproduced", reason = "broke" }, probe_payload("regression_checks.broke", {
    'return function() return false, "broke" end',
  }))
  local missing = probe_payload("regression_checks.missing_probe")
  equal("error", missing.status)
  truthy(missing.message:match("failed to load"), missing.message)
  local bad_type = probe_payload("regression_checks.not_fn", { "return {}" })
  equal("error", bad_type.status)
  truthy(bad_type.message:match("must return a function"), bad_type.message)
  local nil_return = probe_payload("regression_checks.nil_return", { "return function() end" })
  equal("error", nil_return.status)
  truthy(nil_return.message:match("must return true"), nil_return.message)
  local bad_reason = probe_payload("regression_checks.bad_reason", {
    "return function() return false, 1 end",
  })
  equal("error", bad_reason.status)
  truthy(bad_reason.message:match("optional string reason"), bad_reason.message)
  local thrown = probe_payload("regression_checks.throws", {
    'return function() error("boom", 0) end',
  })
  equal("error", thrown.status)
  truthy(thrown.message:match("bisect test failed: boom"), thrown.message)
  local snapshot = probe_payload("")
  equal(1, snapshot.schema_version)
  equal(nil, snapshot.status)
  truthy(snapshot.plugins)
  truthy(snapshot.errors)
end)

test("custom bisect stops when the child exits nonzero", function()
  with_custom_bisect({
    states = { "healthy", "bad" },
    decoy = false,
    init_prelude = "os.exit(7)",
  }, function(ctx)
    local culprit, err = require("regression.bisect").run(ctx.baseline, ctx.current)
    equal(nil, culprit)
    truthy(type(err) == "string" and err:match("headless probe exited with code 7$"), err)
    assert_live_repo(ctx.culprit_dir, ctx.shas[2], "lua/marker.lua", 'return "bad"')
  end)
end)

test("custom bisect stops when the child times out", function()
  with_custom_bisect({
    states = { "healthy", "bad" },
    decoy = false,
    timeout_ms = 1000,
    init_prelude = "vim.wait(30000, function() return false end)",
  }, function(ctx)
    local culprit, err = require("regression.bisect").run(ctx.baseline, ctx.current)
    equal(nil, culprit)
    truthy(type(err) == "string" and err:match("headless probe timed out$"), err)
    assert_live_repo(ctx.culprit_dir, ctx.shas[2], "lua/marker.lua", 'return "bad"')
  end)
end)

test("custom bisect ignores a written verdict when the probe stops", function()
  local function assert_gate(code, payload, expected)
    with_custom_bisect({
      states = { "healthy", "bad" },
      decoy = false,
    }, function(ctx)
      local util = require("regression.util")
      local real = util.system
      local calls = 0
      util.system = function(argv, opts)
        if argv[1] == vim.v.progpath then
          calls = calls + 1
          local fd = assert(io.open(opts.env.REGRESSION_PROBE_OUTPUT, "w"))
          fd:write(vim.json.encode(payload))
          fd:close()
          return { code = code, stdout = "", stderr = "" }
        end
        return real(argv, opts)
      end
      local ok, err = xpcall(function()
        local culprit, message = require("regression.bisect").run(ctx.baseline, ctx.current)
        equal(nil, culprit)
        truthy(type(message) == "string" and message:match(expected .. "$"), message)
        equal(1, calls)
        assert_live_repo(ctx.culprit_dir, ctx.shas[2], "lua/marker.lua", 'return "bad"')
      end, debug.traceback)
      util.system = real
      if not ok then
        error(err)
      end
    end)
  end
  assert_gate(124, { status = "healthy" }, "headless probe timed out")
  assert_gate(9, { status = "reproduced", reason = "ignored" }, "headless probe exited with code 9")
  with_custom_bisect({
    states = { "healthy", "bad" },
    decoy = false,
  }, function(ctx)
    local previous = vim.env.REGRESSION_PROBE_TEST
    vim.env.REGRESSION_PROBE_TEST = "regression_checks.should_not_inherit"
    require("regression").setup({
      startup = { enabled = false },
      health = { enabled = false },
      bisect = { timeout_ms = 60000, settle_ms = 0 },
    })
    local util = require("regression.util")
    local real = util.system
    local seen
    util.system = function(argv, opts)
      if argv[1] == vim.v.progpath then
        seen = opts.env.REGRESSION_PROBE_TEST
        return { code = 1, stdout = "", stderr = "stopped" }
      end
      return real(argv, opts)
    end
    local ok, err = xpcall(function()
      equal(nil, require("regression.bisect").run(ctx.baseline, ctx.current))
      equal("", seen)
    end, debug.traceback)
    util.system = real
    vim.env.REGRESSION_PROBE_TEST = previous
    if not ok then
      error(err)
    end
  end)
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

