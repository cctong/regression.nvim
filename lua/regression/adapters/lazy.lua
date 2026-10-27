local git = require("regression.git")

local M = {
  name = "lazy",
  unavailable_message = "lazy.nvim is not loaded; call require('lazy').setup() before using regression.nvim",
  is_dirty = git.is_dirty,
  has_revision = git.has_revision,
  checkout = git.checkout,
  revisions_between = git.revisions_between,
  commit_subject = git.commit_subject,
  commit_log = git.commit_log,
}

function M.available()
  return package.loaded["lazy.core.config"] ~= nil or pcall(require, "lazy.core.config")
end

function M.plugins()
  local lazy_config = require("lazy.core.config")
  local plugins = {}
  for key, plugin in pairs(lazy_config.plugins or {}) do
    if plugin.dir and vim.uv.fs_stat(plugin.dir .. "/.git") then
      local name = plugin.name or key
      plugins[name] = {
        name = name,
        dir = vim.fs.normalize(plugin.dir),
        url = plugin.url,
        revision = git.revision(plugin.dir),
        head_ref = git.head_ref(plugin.dir),
      }
    end
  end
  return plugins
end

return M
