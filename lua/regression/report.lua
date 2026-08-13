local M = {}

local REPORT_NAME = "regression://report"

local function find_report_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match("regression://report$") then
      return buf
    end
  end
end

local function show_buf(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  local height = math.min(vim.api.nvim_buf_line_count(buf) + 2, math.max(5, math.floor(vim.o.lines / 2)))
  vim.api.nvim_win_set_height(0, math.max(height, 5))
  vim.wo.wrap = true
  vim.wo.linebreak = true
end

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

function M.show(comparison)
  local lines = vim.split(M.format(comparison), "\n", { plain = true })
  local buf = find_report_buf()
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, REPORT_NAME)
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, nowait = true, desc = "Close report" })
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "regression"
  show_buf(buf)
  return buf
end

return M

