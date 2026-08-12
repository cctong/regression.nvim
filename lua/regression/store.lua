local config = require("regression.config")

local M = {}

local function path()
  return string.format("%s/%s.json", config.options.storage_dir, config.options.profile)
end

function M.path()
  return path()
end

function M.exists()
  return vim.uv.fs_stat(path()) ~= nil
end

function M.load()
  local fd, err = io.open(path(), "r")
  if not fd then
    return nil, err
  end
  local content = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return nil, "invalid baseline: " .. tostring(decoded)
  end
  return decoded
end

function M.save(snapshot)
  vim.fn.mkdir(config.options.storage_dir, "p")
  local target = path()
  local temporary = target .. ".tmp"
  local fd, err = io.open(temporary, "w")
  if not fd then
    return nil, err
  end
  fd:write(vim.json.encode(snapshot))
  fd:write("\n")
  fd:close()
  local ok, rename_err = os.rename(temporary, target)
  if not ok then
    os.remove(temporary)
    return nil, rename_err
  end
  return target
end

return M

