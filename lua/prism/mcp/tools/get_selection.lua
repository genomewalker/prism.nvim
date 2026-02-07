--- prism.nvim MCP Tool: getCurrentSelection / getLatestSelection
--- Gets the current or most recent visual selection
--- @module prism.mcp.tools.get_selection

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Cache for the latest selection
--- @type table|nil
local latest_selection = nil

--- Update the latest selection cache
--- @param selection table Selection data
function M.update_cache(selection)
  latest_selection = vim.deepcopy(selection)
  latest_selection.timestamp = vim.loop.hrtime() / 1e6
end

--- Set up selection tracking autocmds
function M.setup_tracking()
  local config = require("prism.config")
  if not config.get("selection.enabled") then
    return
  end

  local debounce_ms = config.get("selection.debounce_ms") or 150

  local update_selection = util.debounce(function()
    local mode = vim.fn.mode()
    if mode:match("[vV\22]") then
      local selection = M.get_current_selection_data()
      if selection then
        M.update_cache(selection)
        event.emit(event.events.SELECTION_CHANGED, selection)
      end
    end
  end, debounce_ms)

  vim.api.nvim_create_autocmd({ "CursorMoved", "ModeChanged" }, {
    group = vim.api.nvim_create_augroup("PrismSelectionTracking", { clear = true }),
    callback = function()
      update_selection()
    end,
  })
end

--- Get current selection data
--- @return table|nil Selection data
function M.get_current_selection_data()
  local mode = vim.fn.mode()

  -- Check if in visual mode
  if not mode:match("[vV\22]") then
    return nil
  end

  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local file_path = vim.api.nvim_buf_get_name(buf)

  -- Get selection range
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")

  local start_row = start_pos[2]
  local start_col = start_pos[3]
  local end_row = end_pos[2]
  local end_col = end_pos[3]

  -- Normalize order
  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  -- Get selected text
  local lines = vim.api.nvim_buf_get_lines(buf, start_row - 1, end_row, false)
  if #lines == 0 then
    return nil
  end

  local selected_text
  if mode == "V" then
    -- Line-wise selection
    selected_text = table.concat(lines, "\n")
  elseif mode == "\22" then
    -- Block-wise selection
    local block_lines = {}
    for _, line in ipairs(lines) do
      local col_start = math.min(start_col, #line + 1)
      local col_end = math.min(end_col, #line)
      table.insert(block_lines, line:sub(col_start, col_end))
    end
    selected_text = table.concat(block_lines, "\n")
  else
    -- Character-wise selection
    if #lines == 1 then
      selected_text = lines[1]:sub(start_col, end_col)
    else
      lines[1] = lines[1]:sub(start_col)
      lines[#lines] = lines[#lines]:sub(1, end_col)
      selected_text = table.concat(lines, "\n")
    end
  end

  return {
    filePath = file_path,
    text = selected_text,
    range = {
      start = { line = start_row, character = start_col },
      ["end"] = { line = end_row, character = end_col },
    },
    mode = mode,
    bufnr = buf,
    winnr = win,
  }
end

--- getCurrentSelection tool definition
M.current_definition = {
  description = "Get the currently active visual selection in the editor",
  inputSchema = {
    type = "object",
    properties = {},
    required = {},
  },
  handler = function(_params, _call_id)
    local selection = M.get_current_selection_data()

    if not selection then
      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              hasSelection = false,
              message = "No active selection",
            }),
          },
        },
        isError = false,
      }
    end

    return {
      content = {
        {
          type = "text",
          text = util.json_encode({
            hasSelection = true,
            filePath = selection.filePath,
            text = selection.text,
            range = selection.range,
            mode = selection.mode,
          }),
        },
      },
      isError = false,
    }
  end,
}

--- getLatestSelection tool definition
M.latest_definition = {
  description = "Get the most recently captured selection (even if no longer active)",
  inputSchema = {
    type = "object",
    properties = {
      maxAge = {
        type = "integer",
        description = "Maximum age in milliseconds (optional, returns any age if not specified)",
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    -- First try current selection
    local current = M.get_current_selection_data()
    if current then
      M.update_cache(current)
      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              hasSelection = true,
              isCurrent = true,
              filePath = current.filePath,
              text = current.text,
              range = current.range,
              mode = current.mode,
            }),
          },
        },
        isError = false,
      }
    end

    -- Fall back to cached selection
    if not latest_selection then
      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              hasSelection = false,
              message = "No selection has been captured",
            }),
          },
        },
        isError = false,
      }
    end

    -- Check age if specified
    if params.maxAge then
      local now = vim.loop.hrtime() / 1e6
      local age = now - (latest_selection.timestamp or 0)
      if age > params.maxAge then
        return {
          content = {
            {
              type = "text",
              text = util.json_encode({
                hasSelection = false,
                message = string.format("Selection too old (%.0fms > %dms)", age, params.maxAge),
              }),
            },
          },
          isError = false,
        }
      end
    end

    return {
      content = {
        {
          type = "text",
          text = util.json_encode({
            hasSelection = true,
            isCurrent = false,
            filePath = latest_selection.filePath,
            text = latest_selection.text,
            range = latest_selection.range,
            mode = latest_selection.mode,
            age = vim.loop.hrtime() / 1e6 - (latest_selection.timestamp or 0),
          }),
        },
      },
      isError = false,
    }
  end,
}

--- Clear the selection cache
function M.clear_cache()
  latest_selection = nil
end

--- Register this tool with the registry
--- @param registry table Tool registry
function M.register(registry)
  registry.register("getCurrentSelection", M.current_definition)
  registry.register("getLatestSelection", M.latest_definition)
  M.setup_tracking()
end

return M
