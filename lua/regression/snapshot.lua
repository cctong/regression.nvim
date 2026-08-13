local util = require("regression.util")

local M = {}

M.SCHEMA_VERSION = 1

local function fail(path, expected)
  return nil, string.format('baseline field "%s" must be %s', path, expected)
end

local function expect_string(value, path)
  if type(value) ~= "string" then
    return fail(path, "a string")
  end
  return true
end

local function expect_number(value, path)
  if type(value) ~= "number" then
    return fail(path, "a number")
  end
  return true
end

local function expect_boolean(value, path)
  if type(value) ~= "boolean" then
    return fail(path, "a boolean")
  end
  return true
end

local function expect_string_list(value, path)
  if type(value) ~= "table" or not vim.islist(value) then
    return fail(path, "a list")
  end
  for index, item in ipairs(value) do
    if type(item) ~= "string" then
      return fail(string.format("%s[%d]", path, index), "a string")
    end
  end
  return true
end

-- Accepts an empty table as map-like regardless of whether JSON decoded it from
-- {} or [], because current snapshots encode empty Lua map fields as [].
local function expect_map(value, path)
  if type(value) ~= "table" or (vim.tbl_count(value) > 0 and vim.islist(value)) then
    return fail(path, "an object")
  end
  for key in pairs(value) do
    if type(key) ~= "string" then
      return nil, string.format('baseline field "%s" must map string keys to values', path)
    end
  end
  return true
end

local function validate_health(health, path)
  if type(health) ~= "table" then
    return fail(path, "an object")
  end
  local ok, err = expect_number(health.failures, path .. ".failures")
  if not ok then return nil, err end
  ok, err = expect_number(health.warnings, path .. ".warnings")
  if not ok then return nil, err end
  ok, err = expect_boolean(health.command_ok, path .. ".command_ok")
  if not ok then return nil, err end
  ok, err = expect_string_list(health.failure_messages, path .. ".failure_messages")
  if not ok then return nil, err end
  ok, err = expect_string_list(health.warning_messages, path .. ".warning_messages")
  if not ok then return nil, err end
  return true
end

local function validate_config_files(config_files, path)
  local ok, err = expect_map(config_files, path)
  if not ok then return nil, err end
  for _, name in ipairs(util.sorted_keys(config_files)) do
    ok, err = expect_string(config_files[name], string.format("%s.%s", path, name))
    if not ok then return nil, err end
  end
  return true
end

local function validate_lsp(lsp, path)
  local ok, err = expect_map(lsp, path)
  if not ok then return nil, err end
  for _, name in ipairs(util.sorted_keys(lsp)) do
    local client = lsp[name]
    local client_path = string.format("%s.%s", path, name)
    if type(client) ~= "table" then
      return fail(client_path, "an object")
    end
    if client.initialized ~= nil then
      ok, err = expect_boolean(client.initialized, client_path .. ".initialized")
      if not ok then return nil, err end
    end
    if client.stopped ~= nil then
      ok, err = expect_boolean(client.stopped, client_path .. ".stopped")
      if not ok then return nil, err end
    end
  end
  return true
end

local function validate_plugins(plugins, path)
  local ok, err = expect_map(plugins, path)
  if not ok then return nil, err end
  for _, name in ipairs(util.sorted_keys(plugins)) do
    local plugin = plugins[name]
    local plugin_path = string.format("%s.%s", path, name)
    if type(plugin) ~= "table" then
      return fail(plugin_path, "an object")
    end
    if plugin.revision ~= nil then
      ok, err = expect_string(plugin.revision, plugin_path .. ".revision")
      if not ok then return nil, err end
    end
  end
  return true
end

function M.validate(value)
  if type(value) ~= "table" or vim.islist(value) then
    return nil, "baseline must be a JSON object"
  end
  if value.schema_version == nil then
    return nil, 'baseline field "schema_version" is required'
  end
  if type(value.schema_version) ~= "number" then
    return nil, 'baseline field "schema_version" must be a number'
  end
  if value.schema_version ~= M.SCHEMA_VERSION then
    return nil, string.format("unsupported baseline schema version %s (supported: %d)", value.schema_version, M.SCHEMA_VERSION)
  end

  local ok, err = expect_string(value.captured_at, "captured_at")
  if not ok then return nil, err end
  ok, err = expect_string(value.nvim_version, "nvim_version")
  if not ok then return nil, err end
  ok, err = expect_string(value.adapter, "adapter")
  if not ok then return nil, err end
  ok, err = expect_string_list(value.errors, "errors")
  if not ok then return nil, err end
  ok, err = validate_lsp(value.lsp, "lsp")
  if not ok then return nil, err end
  ok, err = validate_plugins(value.plugins, "plugins")
  if not ok then return nil, err end

  if value.startup_ms ~= nil then
    ok, err = expect_number(value.startup_ms, "startup_ms")
    if not ok then return nil, err end
  end
  if value.adapter_error ~= nil then
    ok, err = expect_string(value.adapter_error, "adapter_error")
    if not ok then return nil, err end
  end
  if value.health ~= nil then
    ok, err = validate_health(value.health, "health")
    if not ok then return nil, err end
  end
  if value.config_files ~= nil then
    ok, err = validate_config_files(value.config_files, "config_files")
    if not ok then return nil, err end
  end
  return true
end

return M
