local git = require("regression.git")

local M = {
  name = "pack",
  unavailable_message = "vim.pack is not available; use Neovim 0.12+ or set adapter = \"lazy\"",
  is_dirty = git.is_dirty,
  has_revision = git.has_revision,
  checkout = git.checkout,
  revisions_between = git.revisions_between,
  commit_subject = git.commit_subject,
}

function M.available()
  return vim.pack ~= nil and type(vim.pack.get) == "function"
end

function M.plugins()
  local plugins = {}
  if not M.available() then
    return plugins
  end
  local ok, infos = pcall(vim.pack.get, nil, { info = false })
  if not ok or type(infos) ~= "table" then
    return plugins
  end
  for _, info in ipairs(infos) do
    local spec = info.spec or {}
    local name = spec.name
    local dir = info.path
    if name and dir and vim.uv.fs_stat(dir .. "/.git") then
      plugins[name] = {
        name = name,
        dir = vim.fs.normalize(dir),
        url = spec.src,
        revision = git.revision(dir) or info.rev,
        head_ref = git.head_ref(dir),
      }
    end
  end
  return plugins
end

return M
