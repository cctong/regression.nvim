local git = require("regression.git")

local M = {}

local function unlink(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then
    return true
  end
  if stat.type == "link" then
    vim.uv.fs_unlink(path)
    if vim.uv.fs_lstat(path) then
      return nil, "could not unlink " .. path
    end
    return true
  end
  local gitfile = vim.uv.fs_lstat(path .. "/.git")
  if gitfile and gitfile.type == "file" then
    vim.fn.delete(path, "rf")
    return true
  end
  return nil, "refusing to delete " .. path
end

local function canonical_path(path)
  local real = vim.uv.fs_realpath(path)
  if not real or real == "" then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(real)
end

local function explode(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then
    return nil, "missing " .. path
  end
  if stat.type ~= "link" then
    return true
  end
  local target = vim.uv.fs_readlink(path)
  if not target then
    return nil, "could not read symlink " .. path
  end
  if not target:match("^/") then
    target = vim.fs.normalize(vim.fn.fnamemodify(path, ":h") .. "/" .. target)
  end
  local unlinked, unlink_err = unlink(path)
  if not unlinked then
    return nil, unlink_err
  end
  vim.fn.mkdir(path, "p")
  local handle = vim.uv.fs_scandir(target)
  if handle then
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      vim.uv.fs_symlink(target .. "/" .. name, path .. "/" .. name)
    end
  end
  return true
end

function M.create(real_data)
  real_data = vim.fs.normalize(real_data or vim.fn.stdpath("data"))
  local home = vim.fn.tempname() .. "-xdg"
  local data = home .. "/nvim"
  vim.fn.mkdir(data, "p")
  local handle = vim.uv.fs_scandir(real_data)
  if handle then
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      vim.uv.fs_symlink(real_data .. "/" .. name, data .. "/" .. name)
    end
  end
  return {
    home = home,
    real_data = real_data,
    data = data,
    worktrees = {},
  }
end

function M.path(shadow, real_path)
  real_path = vim.fs.normalize(real_path)
  if real_path == shadow.real_data then
    return shadow.data
  end
  local prefix = shadow.real_data .. "/"
  if real_path:sub(1, #prefix) ~= prefix then
    return nil
  end
  return shadow.data .. "/" .. real_path:sub(#prefix + 1)
end

function M.use_revision(shadow, plugin, revision_id)
  local dest = M.path(shadow, plugin.dir)
  if not dest then
    return nil, "plugin is not under stdpath('data')"
  end
  local rel = plugin.dir:sub(#shadow.real_data + 2)
  local parts = vim.split(rel, "/", { plain = true, trimempty = true })
  local acc = shadow.data
  for index = 1, #parts - 1 do
    acc = acc .. "/" .. parts[index]
    local exploded, explode_err = explode(acc)
    if not exploded then
      return nil, explode_err
    end
  end
  if shadow.worktrees[plugin.dir] then
    git.worktree_remove(plugin, dest)
    shadow.worktrees[plugin.dir] = nil
  else
    local unlinked, unlink_err = unlink(dest)
    if not unlinked then
      return nil, unlink_err
    end
  end
  local added, add_err = git.worktree_add(plugin, revision_id, dest)
  if not added then
    return nil, add_err
  end
  shadow.worktrees[plugin.dir] = dest
  return dest
end

function M.use_live(shadow, plugin)
  local dest = M.path(shadow, plugin.dir)
  if not dest then
    return true
  end
  if canonical_path(dest) == canonical_path(plugin.dir) and not shadow.worktrees[plugin.dir] then
    return true
  end
  if shadow.worktrees[plugin.dir] or (vim.uv.fs_lstat(dest .. "/.git") or {}).type == "file" then
    local removed, remove_err = git.worktree_remove(plugin, dest)
    if not removed then
      return nil, remove_err
    end
    shadow.worktrees[plugin.dir] = nil
  else
    local unlinked, unlink_err = unlink(dest)
    if not unlinked then
      return nil, unlink_err
    end
  end
  if not vim.uv.fs_lstat(dest) then
    vim.uv.fs_symlink(plugin.dir, dest)
  end
  return true
end

function M.destroy(shadow)
  local first_err
  for dir, path in pairs(shadow.worktrees) do
    local removed, err = git.worktree_remove({ dir = dir }, path)
    if not removed and not first_err then
      first_err = err
    end
  end
  shadow.worktrees = {}
  vim.fn.delete(shadow.home, "rf")
  if first_err then
    return nil, first_err
  end
  return true
end

return M
