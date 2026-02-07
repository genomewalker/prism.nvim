--- prism.nvim animated spinner for processing states
--- @module prism.ui.spinner

local M = {}

--- State
local state = {
  timer = nil,
  frame_index = 1,
  is_running = false,
  callback = nil,
}

--- Default spinner frames
local default_frames = { "", "", "", "", "", "", "", "", "", "" }

--- Configuration
local config = {
  frames = default_frames,
  interval = 80, -- ms between frames
}

--- Get current spinner frame
--- @return string Current frame character
local function get_frame()
  return config.frames[state.frame_index] or config.frames[1]
end

--- Advance to next frame
local function next_frame()
  state.frame_index = state.frame_index + 1
  if state.frame_index > #config.frames then
    state.frame_index = 1
  end

  -- Call the update callback if set
  if state.callback then
    state.callback(get_frame())
  end

  -- Trigger statusline redraw
  vim.cmd("redrawstatus")
end

--- Setup spinner
--- @param opts table|nil Configuration options
function M.setup(opts)
  opts = opts or {}

  -- Try to get frames from prism config
  local ok, prism_config = pcall(require, "prism.config")
  if ok then
    local ui_icons = prism_config.get("ui.icons.spinner")
    if ui_icons and type(ui_icons) == "table" then
      config.frames = ui_icons
    end
  end

  -- Override with direct options
  if opts.frames then
    config.frames = opts.frames
  end
  if opts.interval then
    config.interval = opts.interval
  end
end

--- Start the spinner animation
--- @param callback function|nil Optional callback called on each frame with current frame char
function M.start(callback)
  if state.is_running then
    return
  end

  state.is_running = true
  state.frame_index = 1
  state.callback = callback

  -- Create timer for animation
  state.timer = vim.loop.new_timer()
  state.timer:start(0, config.interval, vim.schedule_wrap(function()
    if state.is_running then
      next_frame()
    end
  end))

  -- Emit event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("processing:started")
  end
end

--- Stop the spinner animation
function M.stop()
  if not state.is_running then
    return
  end

  state.is_running = false
  state.callback = nil

  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end

  -- Final redraw
  vim.cmd("redrawstatus")

  -- Emit event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("processing:finished")
  end
end

--- Check if spinner is running
--- @return boolean
function M.is_running()
  return state.is_running
end

--- Get current spinner frame (for statusline integration)
--- @return string Current frame or empty string if not running
function M.get()
  if not state.is_running then
    return ""
  end
  return get_frame()
end

--- Get spinner with text
--- @param text string|nil Optional text to show after spinner
--- @return string Spinner frame with optional text
function M.get_with_text(text)
  if not state.is_running then
    return ""
  end
  if text then
    return get_frame() .. " " .. text
  end
  return get_frame()
end

--- Get lualine component for spinner
--- @return table Lualine component config
function M.get_component()
  return {
    function()
      return M.get()
    end,
    cond = function()
      return state.is_running
    end,
    color = { fg = "#61afef" },
  }
end

--- Run a function with spinner
--- @param fn function The async function to run
--- @param text string|nil Optional status text
function M.wrap(fn, text)
  M.start(function(frame)
    if text then
      vim.api.nvim_echo({ { frame .. " " .. text, "PrismSpinner" } }, false, {})
    end
  end)

  -- Run the function
  local ok, result = pcall(fn)

  M.stop()
  vim.api.nvim_echo({ { "" } }, false, {}) -- Clear echo

  if not ok then
    error(result)
  end

  return result
end

return M
