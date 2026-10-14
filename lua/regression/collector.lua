local adapters = require("regression.adapters")
local config = require("regression.config")
local snapshot = require("regression.snapshot")
local util = require("regression.util")

local M = {}

local function startup_time()
  if not config.options.startup.enabled or vim.env.REGRESSION_SKIP_STARTUP == "1" then
    return nil
  end
  local temp = vim.fn.tempname()
  local result = util.system({ vim.v.progpath, "--headless", "--startuptime", temp, "+qa!" }, {
    env = { REGRESSION_SKIP_STARTUP = "1" },
    timeout = config.options.bisect.timeout_ms,
  })
  local elapsed
  local fd = io.open(temp, "r")
  if fd then
    for line in fd:lines() do
      local value = line:match("^%s*([%d.]+)%s+.*NVIM STARTED")
      if value then
        elapsed = tonumber(value)
      end
    end
    fd:close()
  end
  os.remove(temp)
  if result.code == 0 then
    return elapsed
  end
end

local function errors()
  local seen, result = {}, {}
  local messages = vim.api.nvim_exec2("messages", { output = true }).output
  for _, line in ipairs(util.lines(messages)) do
    if line:match("[Ee]rror") or line:match("E%d%d%d:") then
      line = util.trim(line)
      if line ~= "" and not seen[line] then
        seen[line] = true
        result[#result + 1] = line
      end
    end
  end
  local errmsg = util.trim(vim.v.errmsg)
  if errmsg ~= "" and not seen[errmsg] then
    result[#result + 1] = errmsg
  end
  while #result > config.options.errors.max_messages do
    table.remove(result, 1)
  end
  table.sort(result)
  return result
end

local function lsp()
  local result = {}
  if not vim.lsp or not vim.lsp.get_clients then
    return result
  end
  for _, client in ipairs(vim.lsp.get_clients()) do
    result[client.name] = {
      initialized = client.initialized == true,
      stopped = client:is_stopped(),
      root_dir = client.config and client.config.root_dir or nil,
    }
  end
  return result
end

local CAPTURE_TIMEOUT_MS = 10000

local function has_marker(line, marker)
  if line:sub(1, #marker) ~= marker then
    return false
  end
  local boundary = line:sub(#marker + 1, #marker + 1)
  return boundary == "" or boundary == " " or boundary == ":" or boundary == "\t"
end

local function is_health_name(name)
  return type(name) == "string" and name:sub(-9) == "health://"
end

function M.parse_health(lines)
  local failures, warnings = 0, 0
  local failure_messages, warning_messages = {}, {}
  local seen_failures, seen_warnings = {}, {}
  for _, line in ipairs(lines or {}) do
    line = util.trim(line)
    local level
    if has_marker(line, "- ❌ ERROR") or has_marker(line, "- ERROR") or line:sub(1, 6) == "ERROR:" then
      level = "error"
    elseif has_marker(line, "- ⚠️ WARNING") or has_marker(line, "- WARNING") then
      level = "warning"
    end
    if level == "error" then
      failures = failures + 1
      if line ~= "" and not seen_failures[line] then
        seen_failures[line] = true
        failure_messages[#failure_messages + 1] = line
      end
    elseif level == "warning" then
      warnings = warnings + 1
      if line ~= "" and not seen_warnings[line] then
        seen_warnings[line] = true
        warning_messages[#warning_messages + 1] = line
      end
    end
  end
  table.sort(failure_messages)
  table.sort(warning_messages)
  return {
    failures = failures,
    warnings = warnings,
    failure_messages = failure_messages,
    warning_messages = warning_messages,
  }
end

local function editor_context()
  return {
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
  }
end

local function restore_context(ctx)
  local problems = {}
  local function attempt(label, valid, action)
    if not valid then
      return
    end
    local restored, restore_err = pcall(action)
    if not restored then
      problems[#problems + 1] = "could not restore " .. label .. ": " .. tostring(restore_err)
    end
  end
  attempt("tab", ctx.tab and vim.api.nvim_tabpage_is_valid(ctx.tab) and vim.api.nvim_get_current_tabpage() ~= ctx.tab, function()
    vim.api.nvim_set_current_tabpage(ctx.tab)
  end)
  attempt("window", ctx.win and vim.api.nvim_win_is_valid(ctx.win), function()
    if vim.api.nvim_get_current_win() ~= ctx.win then
      vim.api.nvim_set_current_win(ctx.win)
    end
  end)
  attempt("buffer", ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf), function()
    if vim.api.nvim_get_current_buf() ~= ctx.buf then
      vim.api.nvim_set_current_buf(ctx.buf)
    end
  end)
  if ctx.tab and vim.api.nvim_tabpage_is_valid(ctx.tab) and vim.api.nvim_get_current_tabpage() ~= ctx.tab then
    problems[#problems + 1] = "could not restore tab"
  end
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_get_current_win() ~= ctx.win then
    problems[#problems + 1] = "could not restore window"
  end
  if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_get_current_buf() ~= ctx.buf then
    problems[#problems + 1] = "could not restore buffer"
  end
  return problems
end

local function known_bufs()
  local set = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    set[buf] = true
  end
  return set
end

local function hold_health_buffers(held)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and is_health_name(vim.api.nvim_buf_get_name(buf)) then
      local item = {
        buf = buf,
        name = vim.api.nvim_buf_get_name(buf),
        modifiable = vim.bo[buf].modifiable,
      }
      held[#held + 1] = item
      vim.bo[buf].modified = false
      vim.bo[buf].modifiable = true
      local renamed, rename_err = pcall(vim.api.nvim_buf_set_name, buf, "regression-health-hold://" .. buf)
      vim.bo[buf].modifiable = item.modifiable
      if not renamed then
        error("checkhealth capture failed: could not preserve an existing health buffer: " .. tostring(rename_err))
      end
    end
  end
end

local function restore_held(held)
  local problems = {}
  for _, item in ipairs(held) do
    if vim.api.nvim_buf_is_valid(item.buf) then
      vim.bo[item.buf].modified = false
      vim.bo[item.buf].modifiable = true
      local renamed, rename_err = pcall(vim.api.nvim_buf_set_name, item.buf, item.name)
      vim.bo[item.buf].modifiable = item.modifiable
      if not renamed then
        problems[#problems + 1] = "could not restore health buffer name: " .. tostring(rename_err)
      end
    end
  end
  return problems
end

local function append_problems(problems, more)
  for _, problem in ipairs(more) do
    problems[#problems + 1] = problem
  end
end

local function find_new_report(before)
  local fallback
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and not before[buf] then
      if is_health_name(vim.api.nvim_buf_get_name(buf)) then
        return buf
      end
      if vim.bo[buf].filetype == "checkhealth" then
        fallback = buf
      end
    end
  end
  return fallback
end

local function report_ready(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "checkhealth"
end

local function new_report_bufs(before)
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and not before[buf] then
      if is_health_name(vim.api.nvim_buf_get_name(buf)) or vim.bo[buf].filetype == "checkhealth" then
        bufs[#bufs + 1] = buf
      end
    end
  end
  return bufs
end

local function close_capture_windows(bufs, original_wins)
  local problems = {}
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_is_valid(win) and not original_wins[win] and #vim.api.nvim_list_wins() > 1 then
          local closed, close_err = pcall(vim.api.nvim_win_close, win, true)
          if not closed then
            problems[#problems + 1] = "could not close report window: " .. tostring(close_err)
          end
        end
      end
    end
  end
  return problems
end

local function delete_report_bufs(bufs)
  local problems = {}
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      local deleted, delete_err = pcall(vim.api.nvim_buf_delete, buf, { force = true })
      if not deleted then
        problems[#problems + 1] = "could not delete report buffer: " .. tostring(delete_err)
      end
    end
  end
  return problems
end

local function health()
  if not config.options.health.enabled then
    return nil
  end
  local ctx = editor_context()
  local saved_health = vim.g.health
  local saved_eventignore = vim.o.eventignore
  local eventignore_set = false
  local before = known_bufs()
  local original_wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    original_wins[win] = true
  end
  local held = {}
  local lines
  local command_ok = false
  local owned_report
  local owned_group = vim.api.nvim_create_augroup("regression_health_capture", { clear = true })
  vim.api.nvim_create_autocmd("BufNew", {
    group = owned_group,
    callback = function(ev)
      if not owned_report and not before[ev.buf] then
        owned_report = ev.buf
      end
    end,
  })

  local function restore_eventignore()
    if eventignore_set then
      vim.o.eventignore = saved_eventignore
      eventignore_set = false
    end
  end

  local function capture_bufs()
    local bufs = new_report_bufs(before)
    local seen = {}
    for _, buf in ipairs(bufs) do
      seen[buf] = true
    end
    if owned_report and vim.api.nvim_buf_is_valid(owned_report) and not before[owned_report] and not seen[owned_report] then
      bufs[#bufs + 1] = owned_report
    end
    return bufs
  end

  local function cleanup()
    local problems = {}
    local bufs = capture_bufs()
    append_problems(problems, close_capture_windows(bufs, original_wins))
    append_problems(problems, delete_report_bufs(capture_bufs()))
    append_problems(problems, restore_held(held))
    vim.g.health = saved_health
    restore_eventignore()
    pcall(vim.api.nvim_del_augroup_by_id, owned_group)
    append_problems(problems, restore_context(ctx))
    if #problems > 0 then
      error("checkhealth capture failed: " .. table.concat(problems, "; "))
    end
  end

  local ok, err = pcall(function()
    hold_health_buffers(held)
    local override = type(saved_health) == "table" and vim.deepcopy(saved_health) or {}
    override.style = nil
    -- Floating reports, and the BufLeave from a report tab, close existing previews.
    vim.g.health = override
    vim.opt.eventignore:append({ "BufLeave", "WinLeave", "CursorMoved", "CursorMovedI", "InsertCharPre" })
    eventignore_set = true
    local exec_ok, output = pcall(vim.api.nvim_exec2, "silent checkhealth", { output = true })
    command_ok = exec_ok
    if not exec_ok then
      error("checkhealth command failed: " .. tostring(output))
    end
    local report_buf = find_new_report(before)
    if not report_buf then
      error("checkhealth capture failed: no report buffer")
    end
    -- Synchronous :checkhealth sets filetype before it returns. Nightly leaves
    -- the buffer incomplete until an async task sets filetype=checkhealth.
    if not report_ready(report_buf) then
      local completed, status = vim.wait(CAPTURE_TIMEOUT_MS, function()
        if not vim.api.nvim_buf_is_valid(report_buf) then
          return true
        end
        return vim.bo[report_buf].filetype == "checkhealth"
      end, 25)
      if not vim.api.nvim_buf_is_valid(report_buf) then
        error("checkhealth capture failed: report buffer was closed")
      end
      if status == -2 then
        error("checkhealth capture interrupted")
      end
      if completed ~= true or not report_ready(report_buf) then
        error("checkhealth capture timed out")
      end
    end
    local read_ok, read_lines = pcall(vim.api.nvim_buf_get_lines, report_buf, 0, -1, false)
    if not read_ok then
      error("checkhealth capture failed: " .. tostring(read_lines))
    end
    lines = read_lines
  end)

  local cleanup_ok, cleanup_err = pcall(cleanup)
  if not ok then
    if not cleanup_ok then
      error(tostring(err) .. "\n" .. tostring(cleanup_err), 0)
    end
    error(err, 0)
  end
  if not cleanup_ok then
    error(cleanup_err, 0)
  end
  local parsed = M.parse_health(lines)
  parsed.command_ok = command_ok
  return parsed
end

local function should_hash(rel)
  rel = rel:gsub("\\", "/")
  return rel == "init.lua"
    or rel == "init.vim"
    or rel == "lazy-lock.json"
    or rel == "nvim-pack-lock.json"
    or rel:match("^lua/.+%.lua$") ~= nil
end

function M.hash_files(root)
  local hashes = {}
  local function walk(directory, prefix)
    local handle = vim.uv.fs_scandir(directory)
    if not handle then
      return
    end
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if name ~= ".git" then
        local full = directory .. "/" .. name
        local rel = prefix == "" and name or (prefix .. "/" .. name)
        if kind == "directory" then
          walk(full, rel)
        elseif kind == "file" and should_hash(rel) then
          local fd = io.open(full, "rb")
          if fd then
            local content = fd:read("*a") or ""
            fd:close()
            hashes[rel] = vim.fn.sha256(content)
          end
        end
      end
    end
  end
  walk(root, "")
  return hashes
end

function M.collect(opts)
  opts = opts or {}
  local adapter, adapter_err = adapters.get(opts.adapter)
  local plugins = {}
  if adapter then
    plugins = adapter.plugins()
  end
  return {
    schema_version = snapshot.SCHEMA_VERSION,
    captured_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    nvim_version = tostring(vim.version()),
    adapter = adapter and adapter.name or config.options.adapter,
    adapter_error = adapter_err,
    startup_ms = startup_time(),
    errors = errors(),
    lsp = lsp(),
    health = health(),
    config_files = M.hash_files(vim.fn.stdpath("config")),
    plugins = plugins,
  }
end

return M

