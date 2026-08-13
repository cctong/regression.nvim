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
