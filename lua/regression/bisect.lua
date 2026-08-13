local adapters = require("regression.adapters")
local compare = require("regression.compare")
local config = require("regression.config")
local shadow_mod = require("regression.shadow")
local util = require("regression.util")

local M = {}

-- Binary-search a set of changed plugins. test_reverted(group) returns true when
-- reverting that group makes the regression disappear.
function M.locate(candidates, test_reverted)
  local suspects = vim.deepcopy(candidates)
  while #suspects > 1 do
    local midpoint = math.floor(#suspects / 2)
    local group = {}
    for index = 1, midpoint do
      group[#group + 1] = suspects[index]
    end
    if test_reverted(group) then
      suspects = group
    else
      local remainder = {}
      for index = midpoint + 1, #suspects do
        remainder[#remainder + 1] = suspects[index]
      end
      suspects = remainder
    end
  end
  return suspects[1]
end

-- Binary-search commits ordered oldest to newest. is_bad(revision) is true when
-- that revision still reproduces the regression. The last commit is assumed bad.
function M.first_bad(commits, is_bad)
  if not commits or #commits == 0 then
    return nil
  end
  local lo, hi = 1, #commits
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if is_bad(commits[mid]) then
      hi = mid
    else
      lo = mid + 1
    end
  end
  return commits[lo]
end

local function probe(baseline, env)
  local output = vim.fn.tempname()
  local root = util.plugin_root()
  local escaped_root = vim.fn.fnameescape(root)
  local current_file = vim.api.nvim_buf_get_name(0)
  local expected_lsp = util.sorted_keys(baseline.lsp or {})
  env = vim.tbl_extend("force", {
    REGRESSION_PROBE_OUTPUT = output,
    REGRESSION_SKIP_STARTUP = "1",
    REGRESSION_PROBE_FILE = current_file,
    REGRESSION_PROBE_SETTLE_MS = tostring(config.options.bisect.settle_ms),
    REGRESSION_EXPECTED_LSP = vim.json.encode(expected_lsp),
  }, env or {})
  local result = util.system({
    vim.v.progpath,
    "--headless",
    "--cmd", "set runtimepath+=" .. escaped_root,
    "-c", "lua require('regression.probe').run()",
    "-c", "qa!",
  }, {
    env = env,
    timeout = config.options.bisect.timeout_ms,
  })
  local snapshot
  local fd = io.open(output, "r")
  if fd then
    local ok, decoded = pcall(vim.json.decode, fd:read("*a"))
    fd:close()
    if ok then snapshot = decoded end
  end
  os.remove(output)
  if not snapshot then
    return nil, util.trim(result.stderr ~= "" and result.stderr or result.stdout)
  end
  if result.code ~= 0 then
    snapshot.errors = snapshot.errors or {}
    snapshot.errors[#snapshot.errors + 1] = "headless probe exited with code " .. result.code
  end
  return compare.snapshots(baseline, snapshot)
end

function M.run(baseline, current, on_progress)
  local adapter, adapter_err = adapters.get(baseline.adapter)
  if not adapter then return nil, adapter_err end
  local comparison = compare.snapshots(baseline, current)
  if #comparison.plugin_changes == 0 then
    return nil, "no changed plugin revisions to bisect"
  end

  local root = vim.fs.normalize(util.plugin_root())
  local candidates = {}
  for _, change in ipairs(comparison.plugin_changes) do
    local plugin = current.plugins[change.name]
    if plugin and vim.fs.normalize(plugin.dir) ~= root then
      if adapter.is_dirty(plugin) then
        return nil, "refusing to bisect dirty plugin repository: " .. change.name
      end
      if not adapter.has_revision(plugin, change.old_revision) then
        return nil, "baseline revision is unavailable locally for " .. change.name
      end
      candidates[#candidates + 1] = {
        name = change.name,
        plugin = plugin,
        old_revision = change.old_revision,
        new_revision = change.new_revision,
        restore_ref = plugin.head_ref or change.new_revision,
      }
    end
  end
  table.sort(candidates, function(a, b) return a.name < b.name end)
  if #candidates == 0 then
    return nil, "no eligible changed plugins to bisect"
  end

  local function progress(message)
    if on_progress then on_progress(message) end
  end

  local shadow = shadow_mod.create()
  local in_place = {}
  local function probe_now(baseline_snapshot)
    return probe(baseline_snapshot, { XDG_DATA_HOME = shadow.home })
  end
  local function place(candidate, revision)
    if shadow_mod.path(shadow, candidate.plugin.dir) then
      return shadow_mod.use_revision(shadow, candidate.plugin, revision)
    end
    in_place[candidate.name] = true
    return adapter.checkout(candidate.plugin, revision)
  end
  local function checkout_all(revision_key)
    for _, candidate in ipairs(candidates) do
      local ok, err = place(candidate, candidate[revision_key])
      if not ok then return nil, candidate.name .. ": " .. tostring(err) end
    end
    return true
  end
  local function restore()
    for _, candidate in ipairs(candidates) do
      local ok, err
      if in_place[candidate.name] then
        ok, err = adapter.checkout(candidate.plugin, candidate.restore_ref)
      else
        ok, err = shadow_mod.use_live(shadow, candidate.plugin)
      end
      if not ok then return nil, candidate.name .. ": " .. tostring(err) end
    end
    return true
  end

  local ok, value = xpcall(function()
    progress("Checking current revisions...")
    local current_probe, current_err = probe_now(baseline)
    if not current_probe then error(current_err) end
    if not current_probe.has_regressions then
      error("the regression is not reproducible in a clean headless Neovim")
    end

    progress("Verifying the baseline revisions...")
    local checked, checkout_err = checkout_all("old_revision")
    if not checked then error(checkout_err) end
    local baseline_probe, baseline_err = probe_now(baseline)
    if not baseline_probe then error(baseline_err) end
    if baseline_probe.has_regressions then
      error("baseline plugin revisions do not reproduce a healthy state; config or external state may have changed")
    end
    assert(restore())

    local culprit = M.locate(candidates, function(group)
      assert(restore())
      local names = {}
      for _, candidate in ipairs(group) do
        names[#names + 1] = candidate.name
        local switched, switch_err = place(candidate, candidate.old_revision)
        if not switched then error(switch_err) end
      end
      progress("Testing with baseline revisions: " .. table.concat(names, ", "))
      local result, probe_err = probe_now(baseline)
      if not result then error(probe_err) end
      return not result.has_regressions
    end)

    if adapter.revisions_between then
      progress("Bisecting commits in " .. culprit.name .. "...")
      local commits, commits_err = adapter.revisions_between(
        culprit.plugin,
        culprit.old_revision,
        culprit.new_revision
      )
      if not commits then
        progress("Could not list commits in " .. culprit.name .. ": " .. tostring(commits_err))
      elseif #commits > 0 then
        culprit.first_bad_revision = M.first_bad(commits, function(revision)
          assert(restore())
          local switched, switch_err = place(culprit, revision)
          if not switched then error(switch_err) end
          progress("Testing " .. culprit.name .. " at " .. revision:sub(1, 8))
          local result, probe_err = probe_now(baseline)
          if not result then error(probe_err) end
          return result.has_regressions
        end)
        if adapter.commit_subject then
          culprit.first_bad_subject = adapter.commit_subject(culprit.plugin, culprit.first_bad_revision)
        end
      end
    end
    return culprit
  end, debug.traceback)

  local restored, restore_err = restore()
  local destroyed, destroy_err = shadow_mod.destroy(shadow)
  if not restored then
    return nil, "bisect failed to restore current revisions: " .. tostring(restore_err)
  end
  if not destroyed then
    return nil, "bisect failed to remove temporary worktrees: " .. tostring(destroy_err)
  end
  if not ok then
    return nil, tostring(value):match("^[^\n]+")
  end
  return value
end

return M
