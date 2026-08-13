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
  local store = require("regression.store")
  if not store.exists() then
    require("regression.util").notify("No baseline. Run :NvimBaseline first.", vim.log.levels.ERROR)
    return
  end
  local baseline, err = store.load()
  if not baseline then
    require("regression.util").notify(
      "No readable baseline. Update regression.nvim or use :NvimBaseline! to replace it. " .. tostring(err or ""),
      vim.log.levels.ERROR
    )
  end
  return baseline
end

function M.regression()
  local baseline = load_baseline()
  if not baseline then return end
  local current = require("regression.collector").collect()
  local result = require("regression.compare").snapshots(baseline, current)
  require("regression.report").show(result)
  local summary = result.has_regressions
    and string.format("%d regression(s) detected", #result.regressions)
    or "No regressions detected"
  local level = result.has_regressions and vim.log.levels.ERROR or vim.log.levels.INFO
  require("regression.util").notify(summary, level)
  return result
end

function M.health()
  return require("regression.health").run()
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
  local message = string.format(
    "Likely culprit: %s (%s -> %s).",
    culprit.name,
    culprit.old_revision:sub(1, 8),
    culprit.new_revision:sub(1, 8)
  )
  if culprit.first_bad_revision then
    if culprit.first_bad_subject and culprit.first_bad_subject ~= "" then
      message = message .. string.format(
        " First bad commit: %s %s.",
        culprit.first_bad_revision:sub(1, 8),
        culprit.first_bad_subject
      )
    else
      message = message .. string.format(" First bad commit: %s.", culprit.first_bad_revision:sub(1, 8))
    end
  end
  util.notify(message .. " Current revisions were restored.", vim.log.levels.WARN)
  return culprit
end

return M

