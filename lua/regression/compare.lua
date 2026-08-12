local config = require("regression.config")
local util = require("regression.util")

local M = {}

local function array_set(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[value] = true
  end
  return result
end

function M.snapshots(baseline, current)
  local result = {
    regressions = {},
    changes = {},
    plugin_changes = {},
  }

  if baseline.startup_ms and current.startup_ms then
    local delta = current.startup_ms - baseline.startup_ms
    local ratio = baseline.startup_ms > 0 and delta / baseline.startup_ms or 0
    if delta >= config.options.startup.absolute_threshold_ms
      and ratio >= config.options.startup.percent_threshold
    then
      result.regressions[#result.regressions + 1] = {
        kind = "startup",
        message = string.format("startup slowed from %.1f ms to %.1f ms (+%.1f%%)", baseline.startup_ms, current.startup_ms, ratio * 100),
      }
    end
  end

  local old_errors = array_set(baseline.errors)
  for _, message in ipairs(current.errors or {}) do
    if not old_errors[message] then
      result.regressions[#result.regressions + 1] = { kind = "error", message = message }
    end
  end

  for name, old_client in pairs(baseline.lsp or {}) do
    local new_client = (current.lsp or {})[name]
    if not new_client then
      result.regressions[#result.regressions + 1] = { kind = "lsp", message = "LSP client missing: " .. name }
    elseif old_client.initialized and (not new_client.initialized or new_client.stopped) then
      result.regressions[#result.regressions + 1] = { kind = "lsp", message = "LSP client unhealthy: " .. name }
    end
  end

  local old_health, new_health = baseline.health, current.health
  if old_health and new_health then
    if (new_health.failures or 0) > (old_health.failures or 0) then
      result.regressions[#result.regressions + 1] = {
        kind = "health",
        message = string.format("health errors increased from %d to %d", old_health.failures or 0, new_health.failures or 0),
      }
    end
    if (new_health.warnings or 0) > (old_health.warnings or 0) then
      result.regressions[#result.regressions + 1] = {
        kind = "health",
        message = string.format("health warnings increased from %d to %d", old_health.warnings or 0, new_health.warnings or 0),
      }
    end
  end

  local names = {}
  for name in pairs(baseline.plugins or {}) do names[name] = true end
  for name in pairs(current.plugins or {}) do names[name] = true end
  for _, name in ipairs(util.sorted_keys(names)) do
    local old_plugin = (baseline.plugins or {})[name]
    local new_plugin = (current.plugins or {})[name]
    if not old_plugin then
      result.changes[#result.changes + 1] = "plugin added: " .. name
    elseif not new_plugin then
      result.changes[#result.changes + 1] = "plugin removed: " .. name
    elseif old_plugin.revision ~= new_plugin.revision then
      local change = {
        name = name,
        old_revision = old_plugin.revision,
        new_revision = new_plugin.revision,
        dir = new_plugin.dir,
      }
      result.plugin_changes[#result.plugin_changes + 1] = change
      result.changes[#result.changes + 1] = string.format(
        "%s: %s -> %s",
        name,
        (old_plugin.revision or "unknown"):sub(1, 8),
        (new_plugin.revision or "unknown"):sub(1, 8)
      )
    end
  end

  result.has_regressions = #result.regressions > 0
  return result
end

return M

