local M = {}

function M.system(argv, opts)
  opts = opts or {}
  if vim.system then
    return vim.system(argv, {
      cwd = opts.cwd,
      env = opts.env,
      text = true,
      timeout = opts.timeout,
    }):wait()
  end

  local command = table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
  local output = vim.fn.system(command)
  return { code = vim.v.shell_error, stdout = output, stderr = "" }
end

function M.trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.lines(value)
  local result = {}
  for line in (value or ""):gmatch("[^\r\n]+") do
    result[#result + 1] = line
  end
  return result
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "regression.nvim" })
end

function M.plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

function M.sorted_keys(tbl)
  local keys = vim.tbl_keys(tbl or {})
  table.sort(keys)
  return keys
end

return M

