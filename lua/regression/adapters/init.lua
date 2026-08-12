local M = {}

function M.get(name)
  name = name or require("regression.config").options.adapter
  local ok, adapter = pcall(require, "regression.adapters." .. name)
  if not ok then
    return nil, string.format("adapter %q is unavailable: %s", name, adapter)
  end
  if not adapter.available() then
    return nil, adapter.unavailable_message or (name .. " is unavailable")
  end
  return adapter
end

return M

