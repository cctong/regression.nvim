local M = {}

local function first_line(value)
  local text = tostring(value or "")
  return (text:match("^[^\r\n]*") or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function write_result(output, payload)
  local fd, err = io.open(output, "w")
  if not fd then
    error(err)
  end
  fd:write(vim.json.encode(payload))
  fd:close()
end

local function run_test(output, module_name)
  local loaded, mod = pcall(require, module_name)
  if not loaded then
    write_result(output, {
      status = "error",
      message = "bisect test module '" .. module_name .. "' failed to load: " .. first_line(mod),
    })
    return
  end
  if type(mod) ~= "function" then
    write_result(output, {
      status = "error",
      message = "bisect test module '" .. module_name .. "' must return a function",
    })
    return
  end
  local called, healthy, reason = pcall(mod)
  if not called then
    write_result(output, {
      status = "error",
      message = "bisect test failed: " .. first_line(healthy),
    })
    return
  end
  if healthy == true then
    write_result(output, { status = "healthy" })
    return
  end
  if healthy == false and (reason == nil or type(reason) == "string") then
    local payload = { status = "reproduced" }
    if type(reason) == "string" then
      payload.reason = reason
    end
    write_result(output, payload)
    return
  end
  write_result(output, {
    status = "error",
    message = "bisect test must return true, or false with an optional string reason",
  })
end

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
  local test_module = vim.env.REGRESSION_PROBE_TEST
  if test_module and test_module ~= "" then
    run_test(output, test_module)
    return
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
