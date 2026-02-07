--- prism.nvim floating diff preview popup
--- @module prism.ui.diff_popup

local M = {}

--- State
local state = {
  popup = nil,
  is_open = false,
  current_hunk = nil,
}

--- Configuration
local config = {
  width = 80,
  max_height = 30,
  border = "rounded",
  title = " Diff Preview ",
}

--- Setup diff popup
--- @param opts table|nil Configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

--- Format hunk lines for display
--- @param hunk table The hunk object
--- @return string[] Formatted lines
--- @return table[] Highlight info {line, hl_group}
local function format_hunk(hunk)
  local lines = {}
  local highlights = {}

  -- Header
  local header = string.format("@@ -%d,%d +%d,%d @@",
    hunk.old_start or 0,
    hunk.old_count or #hunk.old_lines,
    hunk.start_line or hunk.new_start or 0,
    hunk.new_count or #hunk.new_lines
  )
  table.insert(lines, header)
  table.insert(highlights, { line = 1, hl_group = "PrismMuted" })

  table.insert(lines, "")

  -- Old lines (deletions)
  if hunk.old_lines and #hunk.old_lines > 0 then
    table.insert(lines, "--- Removed:")
    table.insert(highlights, { line = #lines, hl_group = "PrismDiffDeleteSign" })

    for _, line in ipairs(hunk.old_lines) do
      table.insert(lines, "- " .. line)
      table.insert(highlights, { line = #lines, hl_group = "PrismDiffDelVirt" })
    end
    table.insert(lines, "")
  end

  -- New lines (additions)
  if hunk.new_lines and #hunk.new_lines > 0 then
    table.insert(lines, "+++ Added:")
    table.insert(highlights, { line = #lines, hl_group = "PrismDiffAddSign" })

    for _, line in ipairs(hunk.new_lines) do
      table.insert(lines, "+ " .. line)
      table.insert(highlights, { line = #lines, hl_group = "PrismDiffAddVirt" })
    end
  end

  -- Footer with instructions
  table.insert(lines, "")
  table.insert(lines, "Press: y=accept  n=reject  q=close")
  table.insert(highlights, { line = #lines, hl_group = "PrismKeyHint" })

  return lines, highlights
end

--- Show hunk preview popup
--- @param hunk table The hunk to preview
--- @param opts table|nil Additional options
function M.show_hunk_preview(hunk, opts)
  if not hunk then
    require("prism.ui.notify").warn("No hunk to preview")
    return
  end

  -- Close existing popup
  M.close()

  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    require("prism.ui.notify").error("nui.nvim is required for diff popup")
    return
  end

  opts = opts or {}
  local lines, highlights = format_hunk(hunk)

  -- Calculate dimensions
  local height = math.min(#lines + 2, config.max_height)
  local width = config.width

  -- Find longest line
  for _, line in ipairs(lines) do
    width = math.max(width, #line + 4)
  end
  width = math.min(width, vim.o.columns - 4)

  -- Determine title based on hunk type
  local title = config.title
  if hunk.type == "add" then
    title = "  Addition "
  elseif hunk.type == "delete" then
    title = "  Deletion "
  elseif hunk.type == "change" then
    title = "  Change "
  end

  -- Create popup
  state.popup = Popup({
    enter = true,
    focusable = true,
    position = "50%",
    size = {
      width = width,
      height = height,
    },
    border = {
      style = config.border,
      text = {
        top = title,
        top_align = "center",
        bottom = string.format(" Hunk %d ", hunk.id or 0),
        bottom_align = "right",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
    },
    win_options = {
      winblend = 0,
      winhighlight = "Normal:PrismNormal,FloatBorder:PrismBorder,FloatTitle:PrismTitle",
      wrap = false,
      cursorline = false,
    },
  })

  state.popup:mount()
  state.is_open = true
  state.current_hunk = hunk

  -- Set content
  vim.api.nvim_buf_set_option(state.popup.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.popup.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.popup.bufnr, "modifiable", false)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.popup.bufnr, -1, hl.hl_group, hl.line - 1, 0, -1)
  end

  -- Setup keymaps
  local bufnr = state.popup.bufnr

  -- Close
  vim.keymap.set("n", "q", function() M.close() end, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = bufnr, nowait = true })

  -- Accept
  vim.keymap.set("n", "y", function()
    M.close()
    local diff = require("prism.diff")
    diff.accept_hunk(hunk.id)
  end, { buffer = bufnr, nowait = true })

  -- Reject
  vim.keymap.set("n", "n", function()
    M.close()
    local diff = require("prism.diff")
    diff.reject_hunk(hunk.id)
  end, { buffer = bufnr, nowait = true })

  -- Emit event
  local event_ok, event = pcall(require, "prism.event")
  if event_ok then
    event.emit("ui:diff_popup:opened", { hunk_id = hunk.id })
  end
end

--- Show preview for current hunk in active diff
function M.show_current()
  local ok, diff = pcall(require, "prism.diff")
  if not ok then
    require("prism.ui.notify").error("Diff module not available")
    return
  end

  local hunk = diff.get_current_hunk()
  if hunk then
    M.show_hunk_preview(hunk)
  else
    require("prism.ui.notify").info("No active hunk")
  end
end

--- Close the popup
function M.close()
  if state.popup then
    state.popup:unmount()
    state.popup = nil
  end
  state.is_open = false
  state.current_hunk = nil
end

--- Check if popup is open
--- @return boolean
function M.is_open()
  return state.is_open
end

--- Get current hunk being previewed
--- @return table|nil
function M.get_current_hunk()
  return state.current_hunk
end

--- Toggle popup for current hunk
function M.toggle()
  if state.is_open then
    M.close()
  else
    M.show_current()
  end
end

return M
