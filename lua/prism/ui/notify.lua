--- prism.nvim notification system
--- @module prism.ui.notify

local M = {}

--- Notification icons
local icons = {
  info = "",
  warn = "",
  error = "",
  success = "",
  debug = "",
}

--- Notification levels
local levels = {
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
  success = vim.log.levels.INFO,
  debug = vim.log.levels.DEBUG,
}

--- Plugin title for notifications
local TITLE = "prism.nvim"

--- Configuration
local config = {
  enabled = true,
  icons = true,
}

--- Setup notifications
--- @param opts table|nil Configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

--- Format a notification message
--- @param message string The message
--- @param kind string The notification kind
--- @return string Formatted message
local function format_message(message, kind)
  if config.icons and icons[kind] then
    return string.format("%s %s", icons[kind], message)
  end
  return message
end

--- Send a notification
--- @param message string The message to display
--- @param level number vim.log.levels value
--- @param opts table|nil Additional options
local function notify(message, level, opts)
  if not config.enabled then
    return
  end

  opts = opts or {}
  opts.title = opts.title or TITLE

  vim.notify(message, level, opts)
end

--- Info notification
--- @param message string
--- @param opts table|nil
function M.info(message, opts)
  notify(format_message(message, "info"), levels.info, opts)
end

--- Warning notification
--- @param message string
--- @param opts table|nil
function M.warn(message, opts)
  notify(format_message(message, "warn"), levels.warn, opts)
end

--- Error notification
--- @param message string
--- @param opts table|nil
function M.error(message, opts)
  notify(format_message(message, "error"), levels.error, opts)
end

--- Success notification
--- @param message string
--- @param opts table|nil
function M.success(message, opts)
  notify(format_message(message, "success"), levels.success, opts)
end

--- Debug notification (only shown if debug mode is enabled)
--- @param message string
--- @param opts table|nil
function M.debug(message, opts)
  local prism_config = package.loaded["prism.config"]
  if prism_config and prism_config.get("debug") then
    notify(format_message(message, "debug"), levels.debug, opts)
  end
end

--- Progress notification with optional spinner
--- @param message string
--- @param opts table|nil
--- @return function|nil cancel Cancel function if supported
function M.progress(message, opts)
  opts = opts or {}
  opts.title = opts.title or TITLE
  opts.timeout = opts.timeout or false -- Don't auto-dismiss

  local formatted = format_message(message, "info")
  vim.notify(formatted, vim.log.levels.INFO, opts)

  -- Return a cancel function (for nvim-notify or similar)
  return function()
    -- Most notification plugins don't support cancellation
    -- but we return a no-op function for consistency
  end
end

--- Dismiss all prism notifications
function M.dismiss()
  -- Try to dismiss via nvim-notify if available
  local ok, nvim_notify = pcall(require, "notify")
  if ok and nvim_notify.dismiss then
    nvim_notify.dismiss({ pending = true, silent = true })
  end
end

return M
