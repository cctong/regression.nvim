local M = {}

function M.run()
  local output = vim.env.REGRESSION_PROBE_OUTPUT
  if not output or output == "" then
    error("REGRESSION_PROBE_OUTPUT is not set")
  end
  local file = vim.env.REGRESSION_PROBE_FILE
  if file and file ~= "" and vim.uv.fs_stat(file) then
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  local settle_ms = tonumber(vim.env.REGRESSION_PROBE_SETTLE_MS) or 0
  if settle_ms > 0 then
    local expected = {}
    pcall(function()
      expected = vim.json.decode(vim.env.REGRESSION_EXPECTED_LSP or "[]")
    end)
    vim.wait(settle_ms, function()
      local clients = {}
      for _, client in ipairs(vim.lsp.get_clients()) do
        clients[client.name] = client
      end
      for _, name in ipairs(expected) do
        local client = clients[name]
        if not client or not client.initialized or client:is_stopped() then
          return false
        end
      end
      return true
    end, 25)
  end
  local snapshot = require("regression.collector").collect()
  local fd, err = io.open(output, "w")
  if not fd then
    error(err)
  end
  fd:write(vim.json.encode(snapshot))
  fd:close()
end

return M
