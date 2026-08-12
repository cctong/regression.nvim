local M = {}

function M.setup(opts)
  require("regression.config").setup(opts)
end

function M.baseline(opts)
  opts = opts or {}
  local store = require("regression.store")
  if store.exists() and not opts.force then
    require("regression.util").notify("A baseline already exists. Use :NvimBaseline! to replace it.", vim.log.levels.WARN)
    return
  end
  local snapshot = require("regression.collector").collect()
  local path, err = store.save(snapshot)
  if not path then
    require("regression.util").notify("Could not save baseline: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  require("regression.util").notify("Known-good baseline saved to " .. path)
  return snapshot
end

local function load_baseline()
  local baseline, err = require("regression.store").load()
  if not baseline then
    require("regression.util").notify("No readable baseline. Run :NvimBaseline first. " .. tostring(err or ""), vim.log.levels.ERROR)
  end
  return baseline
end

function M.regression()
  local baseline = load_baseline()
  if not baseline then return end
  local current = require("regression.collector").collect()
  local result = require("regression.compare").snapshots(baseline, current)
  local level = result.has_regressions and vim.log.levels.ERROR or vim.log.levels.INFO
  require("regression.util").notify(require("regression.report").format(result), level)
  return result
end

function M.bisect()
  local baseline = load_baseline()
  if not baseline then return end
  local util = require("regression.util")
  local current = require("regression.collector").collect()
  local culprit, err = require("regression.bisect").run(baseline, current, function(message)
    util.notify(message)
  end)
  if not culprit then
    util.notify("Bisect stopped: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  util.notify(string.format(
    "Likely culprit: %s (%s -> %s). Current revisions were restored.",
    culprit.name,
    culprit.old_revision:sub(1, 8),
    culprit.new_revision:sub(1, 8)
  ), vim.log.levels.WARN)
  return culprit
end

return M

