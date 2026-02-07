--- prism.nvim utility module
--- Shared utilities and helpers
--- @module prism.util

local M = {}

--- Generate a UUID v4
--- @return string UUID string
function M.uuid_v4()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (
    string.gsub(template, "[xy]", function(c)
      local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
      return string.format("%x", v)
    end)
  )
end

--- Create a debounced function
--- @param fn function Function to debounce
--- @param ms number Debounce delay in milliseconds
--- @return function Debounced function
function M.debounce(fn, ms)
  local timer = nil
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
      timer:close()
    end
    timer = vim.loop.new_timer()
    timer:start(ms, 0, function()
      timer:stop()
      timer:close()
      timer = nil
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

--- Create a throttled function
--- @param fn function Function to throttle
--- @param ms number Throttle interval in milliseconds
--- @return function Throttled function
function M.throttle(fn, ms)
  local last_call = 0
  local timer = nil
  local pending_args = nil

  return function(...)
    local now = vim.loop.hrtime() / 1e6
    local elapsed = now - last_call

    if elapsed >= ms then
      last_call = now
      fn(...)
    else
      pending_args = { ... }
      if not timer then
        timer = vim.loop.new_timer()
        timer:start(ms - elapsed, 0, function()
          timer:stop()
          timer:close()
          timer = nil
          if pending_args then
            last_call = vim.loop.hrtime() / 1e6
            vim.schedule(function()
              fn(unpack(pending_args))
              pending_args = nil
            end)
          end
        end)
      end
    end
  end
end

--- Schedule function to run on main thread
--- @param fn function Function to schedule
function M.schedule(fn)
  vim.schedule(fn)
end

--- Schedule function to run after delay
--- @param fn function Function to schedule
--- @param ms number Delay in milliseconds
--- @return userdata Timer handle
function M.schedule_after(fn, ms)
  local timer = vim.loop.new_timer()
  timer:start(ms, 0, function()
    timer:stop()
    timer:close()
    vim.schedule(fn)
  end)
  return timer
end

--- Get git root directory
--- @param path string|nil Starting path (defaults to current buffer)
--- @return string|nil Git root path or nil if not in a git repo
function M.git_root(path)
  path = path or vim.fn.expand("%:p:h")

  -- Try using git command
  local result = vim.fn.systemlist({ "git", "-C", path, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and #result > 0 then
    return result[1]
  end

  -- Fallback: walk up directories looking for .git
  local current = path
  while current and current ~= "/" do
    if vim.fn.isdirectory(current .. "/.git") == 1 then
      return current
    end
    current = vim.fn.fnamemodify(current, ":h")
  end

  return nil
end

--- Check if window is floating
--- @param win number|nil Window handle (defaults to current window)
--- @return boolean
function M.is_floating(win)
  win = win or vim.api.nvim_get_current_win()
  local config = vim.api.nvim_win_get_config(win)
  return config.relative ~= ""
end

--- Check if buffer is special (terminal, quickfix, etc.)
--- @param buf number|nil Buffer handle (defaults to current buffer)
--- @return boolean
function M.buf_is_special(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  -- Check buftype
  local buftype = vim.bo[buf].buftype
  if buftype ~= "" then
    return true
  end

  -- Check filetype
  local filetype = vim.bo[buf].filetype
  local special_filetypes = {
    "NvimTree",
    "neo-tree",
    "TelescopePrompt",
    "TelescopeResults",
    "qf",
    "help",
    "man",
    "fugitive",
    "git",
    "packer",
    "lazy",
    "mason",
    "notify",
    "prism",
  }

  for _, ft in ipairs(special_filetypes) do
    if filetype == ft then
      return true
    end
  end

  return false
end

--- JSON encode with error handling
--- @param value any Value to encode
--- @return string|nil json_string
--- @return string|nil error_message
function M.json_encode(value)
  local ok, result = pcall(vim.fn.json_encode, value)
  if ok then
    return result, nil
  else
    return nil, result
  end
end

--- JSON decode with error handling
--- @param str string JSON string to decode
--- @return any|nil value
--- @return string|nil error_message
function M.json_decode(str)
  if not str or str == "" then
    return nil, "empty string"
  end

  local ok, result = pcall(vim.fn.json_decode, str)
  if ok then
    return result, nil
  else
    return nil, result
  end
end

--- Structured logger
M.log = {}

local log_levels = {
  trace = 1,
  debug = 2,
  info = 3,
  warn = 4,
  error = 5,
}

local current_log_level = "info"

--- Set log level
--- @param level string Log level ("trace", "debug", "info", "warn", "error")
function M.log.set_level(level)
  if log_levels[level] then
    current_log_level = level
  end
end

--- Internal log function
--- @param level string Log level
--- @param msg string Message
--- @param data table|nil Additional data
local function do_log(level, msg, data)
  if log_levels[level] < log_levels[current_log_level] then
    return
  end

  local vim_level = ({
    trace = vim.log.levels.TRACE,
    debug = vim.log.levels.DEBUG,
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
  })[level]

  local formatted = string.format("[prism.nvim] [%s] %s", level:upper(), msg)

  if data then
    local json, _ = M.json_encode(data)
    if json then
      formatted = formatted .. " " .. json
    end
  end

  vim.schedule(function()
    vim.notify(formatted, vim_level)
  end)
end

--- Log at trace level
--- @param msg string Message
--- @param data table|nil Additional data
function M.log.trace(msg, data)
  do_log("trace", msg, data)
end

--- Log at debug level
--- @param msg string Message
--- @param data table|nil Additional data
function M.log.debug(msg, data)
  do_log("debug", msg, data)
end

--- Log at info level
--- @param msg string Message
--- @param data table|nil Additional data
function M.log.info(msg, data)
  do_log("info", msg, data)
end

--- Log at warn level
--- @param msg string Message
--- @param data table|nil Additional data
function M.log.warn(msg, data)
  do_log("warn", msg, data)
end

--- Log at error level
--- @param msg string Message
--- @param data table|nil Additional data
function M.log.error(msg, data)
  do_log("error", msg, data)
end

--- Get relative path from git root or cwd
--- @param path string Absolute path
--- @return string Relative path
function M.relative_path(path)
  local root = M.git_root(path) or vim.fn.getcwd()
  if vim.startswith(path, root) then
    local rel = path:sub(#root + 2)
    return rel ~= "" and rel or path
  end
  return path
end

--- Escape string for use in Lua pattern
--- @param str string String to escape
--- @return string Escaped string
function M.escape_pattern(str)
  return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

--- Get visual selection text
--- @return string[] lines Selected lines
--- @return table range { start_row, start_col, end_row, end_col } (1-indexed)
function M.get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local start_row = start_pos[2]
  local start_col = start_pos[3]
  local end_row = end_pos[2]
  local end_col = end_pos[3]

  -- Handle V-LINE mode where end_col is a large number
  if end_col > 100000 then
    end_col = #vim.fn.getline(end_row)
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)

  if #lines == 0 then
    return {}, { start_row, start_col, end_row, end_col }
  end

  -- Adjust first and last lines for character selection
  if #lines == 1 then
    lines[1] = lines[1]:sub(start_col, end_col)
  else
    lines[1] = lines[1]:sub(start_col)
    lines[#lines] = lines[#lines]:sub(1, end_col)
  end

  return lines, { start_row, start_col, end_row, end_col }
end

--- Check if a plugin is available
--- @param plugin string Plugin name (e.g., "nvim-treesitter")
--- @return boolean
function M.has_plugin(plugin)
  local ok, _ = pcall(require, plugin)
  return ok
end

--- Merge multiple tables (shallow)
--- @param ... table Tables to merge
--- @return table Merged table
function M.merge(...)
  local result = {}
  for _, tbl in ipairs({ ... }) do
    for k, v in pairs(tbl) do
      result[k] = v
    end
  end
  return result
end

--- Check if value is in list
--- @param list table List to search
--- @param value any Value to find
--- @return boolean
function M.contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

--- Clamp a number between min and max
--- @param n number Number to clamp
--- @param min number Minimum value
--- @param max number Maximum value
--- @return number Clamped value
function M.clamp(n, min, max)
  return math.min(math.max(n, min), max)
end

return M
