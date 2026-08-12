local M = {}

M.defaults = {
  profile = "default",
  adapter = "lazy",
  storage_dir = vim.fn.stdpath("state") .. "/regression.nvim",
  startup = {
    enabled = true,
    percent_threshold = 0.25,
    absolute_threshold_ms = 20,
  },
  health = {
    enabled = true,
  },
  errors = {
    max_messages = 100,
  },
  bisect = {
    timeout_ms = 60000,
    settle_ms = 1000,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
