local adapters = require("regression.adapters")
local config = require("regression.config")
local report = require("regression.report")
local store = require("regression.store")
local util = require("regression.util")

local M = {}

local function neovim_check()
  local v = vim.version()
  if v.major == 0 and v.minor < 10 then
    return {
      level = "error",
      text = string.format("Neovim 0.10 or newer is required (running %s)", tostring(v)),
    }
  end
  return {
    level = "ok",
    text = string.format("Neovim %s is supported", tostring(v)),
  }
end

local function adapter_check()
  local adapter, err = adapters.get()
  if not adapter then
    return {
      level = "error",
      text = string.format("adapter %q is unavailable: %s", config.options.adapter, err),
    }
  end
  return {
    level = "ok",
    text = string.format("adapter %q is available", adapter.name),
  }
end

local function storage_check()
  local dir = config.options.storage_dir
  local stat = vim.uv.fs_stat(dir)
  if not stat then
    return {
      level = "warn",
      text = string.format("storage dir %s does not exist; :NvimBaseline will create it", dir),
    }
  end
  if stat.type ~= "directory" then
    return {
      level = "error",
      text = string.format("storage dir %s is not a directory", dir),
    }
  end
  if not vim.uv.fs_access(dir, "w") then
    return {
      level = "error",
      text = string.format("storage dir %s is not writable", dir),
    }
  end
  return {
    level = "ok",
    text = string.format("storage dir %s is writable", dir),
  }
end

local function baseline_check()
  if not store.exists() then
    return {
      level = "warn",
      text = "no baseline yet; run :NvimBaseline",
    }
  end
  local baseline, err = store.load()
  if not baseline then
    return {
      level = "error",
      text = string.format("baseline is invalid: %s; update regression.nvim or use :NvimBaseline! to replace it", err),
    }
  end
  return {
    level = "info",
    text = string.format(
      "baseline is valid (schema v%d, %d plugin(s), captured %s)",
      baseline.schema_version or 1,
      vim.tbl_count(baseline.plugins or {}),
      tostring(baseline.captured_at)
    ),
  }
end

function M.check()
  return {
    neovim_check(),
    adapter_check(),
    storage_check(),
    baseline_check(),
  }
end

function M.run()
  local checks = M.check()
  local lines = { "regression.nvim health" }
  local problems = 0
  local errors = 0
  for _, item in ipairs(checks) do
    lines[#lines + 1] = string.format("  [%s] %s", item.level, item.text)
    if item.level == "error" or item.level == "warn" then
      problems = problems + 1
    end
    if item.level == "error" then
      errors = errors + 1
    end
  end
  report.show_lines(lines)
  if errors > 0 then
    util.notify(string.format("Health check complete: %d problem(s) found", problems), vim.log.levels.ERROR)
  elseif problems > 0 then
    util.notify(string.format("Health check complete: %d problem(s) found", problems), vim.log.levels.WARN)
  else
    util.notify("Health check complete: no problems found", vim.log.levels.INFO)
  end
  return checks
end

return M
