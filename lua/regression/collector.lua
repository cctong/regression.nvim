local adapters = require("regression.adapters")
local config = require("regression.config")
local util = require("regression.util")

local M = {}

local function startup_time()
  if not config.options.startup.enabled or vim.env.REGRESSION_SKIP_STARTUP == "1" then
    return nil
  end
  local temp = vim.fn.tempname()
  local result = util.system({ vim.v.progpath, "--headless", "--startuptime", temp, "+qa!" }, {
    env = { REGRESSION_SKIP_STARTUP = "1" },
    timeout = config.options.bisect.timeout_ms,
  })
  local elapsed
  local fd = io.open(temp, "r")
  if fd then
    for line in fd:lines() do
      local value = line:match("^%s*([%d.]+)%s+.*NVIM STARTED")
      if value then
        elapsed = tonumber(value)
      end
    end
    fd:close()
  end
  os.remove(temp)
  if result.code == 0 then
    return elapsed
  end
end

local function errors()
  local seen, result = {}, {}
  local messages = vim.api.nvim_exec2("messages", { output = true }).output
  for _, line in ipairs(util.lines(messages)) do
    if line:match("[Ee]rror") or line:match("E%d%d%d:") then
      line = util.trim(line)
      if line ~= "" and not seen[line] then
        seen[line] = true
        result[#result + 1] = line
      end
    end
  end
  local errmsg = util.trim(vim.v.errmsg)
  if errmsg ~= "" and not seen[errmsg] then
    result[#result + 1] = errmsg
  end
  while #result > config.options.errors.max_messages do
    table.remove(result, 1)
  end
  table.sort(result)
  return result
end

local function lsp()
  local result = {}
  if not vim.lsp or not vim.lsp.get_clients then
    return result
  end
  for _, client in ipairs(vim.lsp.get_clients()) do
    result[client.name] = {
      initialized = client.initialized == true,
      stopped = client:is_stopped(),
      root_dir = client.config and client.config.root_dir or nil,
    }
  end
  return result
end

local function health()
  if not config.options.health.enabled then
    return nil
  end
  local before = vim.api.nvim_get_current_buf()
  local ok, output = pcall(vim.api.nvim_exec2, "silent checkhealth", { output = true })
  local text = ok and output.output or ""
  if text == "" then
    local current = vim.api.nvim_get_current_buf()
    if current ~= before and vim.api.nvim_buf_is_valid(current) then
      text = table.concat(vim.api.nvim_buf_get_lines(current, 0, -1, false), "\n")
      pcall(vim.api.nvim_buf_delete, current, { force = true })
      pcall(vim.api.nvim_set_current_buf, before)
    end
  end
  local failures, warnings = 0, 0
  for _, line in ipairs(util.lines(text)) do
    if line:match("%- ERROR") or line:match("ERROR:") then
      failures = failures + 1
    elseif line:match("%- WARNING") or line:match("WARN") then
      warnings = warnings + 1
    end
  end
  return {
    failures = failures,
    warnings = warnings,
    command_ok = ok,
  }
end

function M.collect(opts)
  opts = opts or {}
  local adapter, adapter_err = adapters.get(opts.adapter)
  local plugins = {}
  if adapter then
    plugins = adapter.plugins()
  end
  return {
    schema_version = 1,
    captured_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    nvim_version = tostring(vim.version()),
    adapter = adapter and adapter.name or config.options.adapter,
    adapter_error = adapter_err,
    startup_ms = startup_time(),
    errors = errors(),
    lsp = lsp(),
    health = health(),
    plugins = plugins,
  }
end

return M

