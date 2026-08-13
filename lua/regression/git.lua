local util = require("regression.util")

local M = {}

function M.revision(dir)
  local result = util.system({ "git", "rev-parse", "HEAD" }, { cwd = dir })
  if result.code == 0 then
    return util.trim(result.stdout)
  end
end

function M.head_ref(dir)
  local result = util.system({ "git", "symbolic-ref", "--quiet", "--short", "HEAD" }, { cwd = dir })
  if result.code == 0 then
    return util.trim(result.stdout)
  end
end

function M.is_dirty(plugin)
  local result = util.system({ "git", "status", "--porcelain" }, { cwd = plugin.dir })
  return result.code ~= 0 or util.trim(result.stdout) ~= ""
end

function M.has_revision(plugin, revision_id)
  local result = util.system({ "git", "cat-file", "-e", revision_id .. "^{commit}" }, { cwd = plugin.dir })
  return result.code == 0
end

function M.checkout(plugin, revision_id)
  local result = util.system({ "git", "checkout", "--quiet", "--detach", revision_id }, { cwd = plugin.dir })
  if result.code ~= 0 then
    return nil, util.trim(result.stderr ~= "" and result.stderr or result.stdout)
  end
  return true
end

function M.worktree_add(plugin, revision_id, path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  if vim.uv.fs_lstat(path) then
    local removed, remove_err = M.worktree_remove(plugin, path)
    if not removed then
      return nil, remove_err
    end
  end
  local result = util.system({
    "git",
    "worktree",
    "add",
    "--detach",
    "--quiet",
    path,
    revision_id,
  }, { cwd = plugin.dir })
  if result.code ~= 0 then
    return nil, util.trim(result.stderr ~= "" and result.stderr or result.stdout)
  end
  return path
end

function M.worktree_remove(plugin, path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if not vim.uv.fs_lstat(path) then
    util.system({ "git", "worktree", "prune" }, { cwd = plugin.dir })
    return true
  end
  local result = util.system({
    "git",
    "worktree",
    "remove",
    "--force",
    path,
  }, { cwd = plugin.dir })
  if result.code ~= 0 then
    util.system({ "git", "worktree", "prune" }, { cwd = plugin.dir })
    local gitfile = vim.uv.fs_lstat(path .. "/.git")
    if gitfile and gitfile.type == "file" then
      vim.fn.delete(path, "rf")
    elseif vim.uv.fs_lstat(path) then
      return nil, util.trim(result.stderr ~= "" and result.stderr or result.stdout)
    end
  end
  return true
end

function M.revisions_between(plugin, old_revision, new_revision)
  local result = util.system({
    "git",
    "rev-list",
    "--reverse",
    old_revision .. ".." .. new_revision,
  }, { cwd = plugin.dir })
  if result.code ~= 0 then
    return nil, util.trim(result.stderr ~= "" and result.stderr or result.stdout)
  end
  local commits = {}
  for _, line in ipairs(util.lines(result.stdout)) do
    line = util.trim(line)
    if line ~= "" then
      commits[#commits + 1] = line
    end
  end
  return commits
end

function M.commit_subject(plugin, revision_id)
  local result = util.system({ "git", "log", "-1", "--format=%s", revision_id }, { cwd = plugin.dir })
  if result.code == 0 then
    return util.trim(result.stdout)
  end
end

return M
