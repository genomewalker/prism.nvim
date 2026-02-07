---@module 'prism.review.status'
--- Status Widget for Review Sessions
--- Shows current review progress in a non-intrusive way

local M = {}

local review = require("prism.review")

-- State
local state = {
  enabled = false,
  timer = nil,
}

-- Update statusline with review info
local function update_statusline()
  local status = review.get_status()
  if not status then
    -- No active review - clear custom statusline
    if vim.g.prism_review_statusline then
      vim.g.prism_review_statusline = nil
    end
    return
  end

  -- Build status string
  local filename = vim.fn.fnamemodify(status.file, ":t")
  local str = string.format(
    "[Prism] %s: %d/%d hunks | y:accept n:reject Tab:next",
    filename,
    status.current_hunk,
    status.total_hunks
  )

  vim.g.prism_review_statusline = str
end

--- Start status updates
function M.start()
  if state.enabled then return end
  state.enabled = true

  -- Update every 100ms while active
  state.timer = vim.loop.new_timer()
  state.timer:start(0, 100, vim.schedule_wrap(function()
    if not review.is_active() then
      M.stop()
      return
    end
    update_statusline()
  end))
end

--- Stop status updates
function M.stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  state.enabled = false
  vim.g.prism_review_statusline = nil
end

--- Get current status string (for use in custom statuslines)
---@return string|nil
function M.get_string()
  return vim.g.prism_review_statusline
end

return M
