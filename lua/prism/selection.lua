--- prism.nvim selection tracking module
--- Track visual selections for Claude context
--- @module prism.selection

local M = {}

local config = require("prism.config")
local event = require("prism.event")

--- Selection state
--- @type table
local state = {
  current = nil, -- Current active selection
  latest = nil, -- Most recent selection (persists after leaving visual mode)
  timer = nil, -- Debounce timer
  autocmd_group = nil, -- Autocmd group ID
}

--- Get visual selection range and text
--- @return table|nil Selection info
local function capture_selection()
  local mode = vim.fn.mode()

  -- Check if in visual mode
  local is_visual = mode == "v" or mode == "V" or mode == "\22"

  local start_pos, end_pos

  if is_visual then
    start_pos = vim.fn.getpos("v")
    end_pos = vim.fn.getpos(".")
  else
    -- Use visual marks
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")

    if start_pos[2] == 0 and end_pos[2] == 0 then
      return nil
    end
  end

  -- Normalize positions (start should be before end)
  local start_line, start_col = start_pos[2], start_pos[3]
  local end_line, end_col = end_pos[2], end_pos[3]

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  -- Get lines
  local lines = vim.fn.getline(start_line, end_line)
  if type(lines) == "string" then
    lines = { lines }
  end

  if #lines == 0 then
    return nil
  end

  -- Handle visual mode types
  local text
  if mode == "V" then
    -- Line-wise: full lines
    text = table.concat(lines, "\n")
  elseif mode == "\22" then
    -- Block-wise: extract columns
    local block_lines = {}
    for _, line in ipairs(lines) do
      local block = line:sub(start_col, end_col)
      table.insert(block_lines, block)
    end
    text = table.concat(block_lines, "\n")
  else
    -- Character-wise
    if #lines == 1 then
      text = lines[1]:sub(start_col, end_col)
    else
      lines[1] = lines[1]:sub(start_col)
      lines[#lines] = lines[#lines]:sub(1, end_col)
      text = table.concat(lines, "\n")
    end
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.fn.expand("%:p")
  local filetype = vim.bo[bufnr].filetype

  return {
    text = text,
    start_line = start_line,
    end_line = end_line,
    start_col = start_col,
    end_col = end_col,
    mode = mode,
    bufnr = bufnr,
    file = file,
    filetype = filetype,
    timestamp = vim.loop.hrtime() / 1e6,
  }
end

--- Send selection update via MCP
local function send_update()
  if not state.current then
    return
  end

  -- Emit event for MCP to pick up
  event.emit(event.events.SELECTION_CHANGED, state.current)
end

--- Handle selection change (debounced)
local function on_selection_change()
  local sel_config = config.get("selection") or {}

  -- Cancel existing timer
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end

  -- Capture immediately
  local selection = capture_selection()
  if selection then
    state.current = selection
    state.latest = selection
  end

  -- Debounce the MCP update
  local debounce_ms = sel_config.debounce_ms or 150
  state.timer = vim.loop.new_timer()
  state.timer:start(debounce_ms, 0, vim.schedule_wrap(function()
    send_update()
    if state.timer then
      state.timer:stop()
      state.timer:close()
      state.timer = nil
    end
  end))
end

--- Handle leaving visual mode
local function on_mode_leave()
  -- Keep latest selection when leaving visual mode
  if state.current then
    state.latest = state.current
  end
  state.current = nil
end

--- Setup selection tracking
--- @param opts table|nil Configuration options
function M.setup(opts)
  local sel_config = config.get("selection") or {}

  if sel_config.enabled == false then
    return
  end

  -- Clean up existing autocmds
  if state.autocmd_group then
    vim.api.nvim_del_augroup_by_id(state.autocmd_group)
  end

  state.autocmd_group = vim.api.nvim_create_augroup("PrismSelection", { clear = true })

  -- Track cursor movement in visual mode
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.autocmd_group,
    callback = function()
      local mode = vim.fn.mode()
      if mode == "v" or mode == "V" or mode == "\22" then
        on_selection_change()
      end
    end,
  })

  -- Track mode changes
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = state.autocmd_group,
    pattern = "*:[vV\22]*", -- Entering visual mode
    callback = function()
      on_selection_change()
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = state.autocmd_group,
    pattern = "[vV\22]*:*", -- Leaving visual mode
    callback = function()
      on_mode_leave()
    end,
  })

  -- Track visual selection after operations
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = state.autocmd_group,
    callback = function()
      -- Capture selection after yank
      vim.schedule(function()
        local selection = capture_selection()
        if selection then
          state.latest = selection
        end
      end)
    end,
  })
end

--- Get current active selection (only valid in visual mode)
--- @return table|nil Current selection
function M.get_current()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    return capture_selection()
  end
  return state.current
end

--- Get most recent selection (persists after leaving visual mode)
--- @return table|nil Latest selection
function M.get_latest()
  -- Try to get from visual marks if no cached selection
  if not state.latest then
    state.latest = capture_selection()
  end
  return state.latest
end

--- Clear selection state
function M.clear()
  state.current = nil
  state.latest = nil
end

--- Manually trigger selection update
function M.refresh()
  local selection = capture_selection()
  if selection then
    state.current = selection
    state.latest = selection
    send_update()
  end
end

--- Disable selection tracking
function M.disable()
  if state.autocmd_group then
    vim.api.nvim_del_augroup_by_id(state.autocmd_group)
    state.autocmd_group = nil
  end

  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

--- Check if tracking is enabled
--- @return boolean enabled
function M.is_enabled()
  return state.autocmd_group ~= nil
end

return M
