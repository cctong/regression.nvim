local M = {}

function M.format(comparison)
  local lines = { "regression.nvim" }
  if comparison.has_regressions then
    lines[#lines + 1] = string.format("%d regression(s) detected", #comparison.regressions)
    for _, item in ipairs(comparison.regressions) do
      lines[#lines + 1] = string.format("  x [%s] %s", item.kind, item.message)
    end
  else
    lines[#lines + 1] = "No regressions detected"
  end
  if #comparison.changes > 0 then
    lines[#lines + 1] = string.format("%d environment change(s)", #comparison.changes)
    for _, item in ipairs(comparison.changes) do
      lines[#lines + 1] = "  - " .. item
    end
  end
  return table.concat(lines, "\n")
end

return M

