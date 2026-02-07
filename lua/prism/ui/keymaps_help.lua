--- prism.nvim floating keymap cheatsheet
--- @module prism.ui.keymaps_help

local M = {}

--- State
local state = {
  popup = nil,
  is_open = false,
}

--- Configuration
local config = {
  width = 60,
  border = "rounded",
  title = " Prism Keymaps ",
}

--- Default keymaps (will be overridden by config)
local default_keymaps = {
  { key = "<leader>cc", action = "Toggle Claude terminal", category = "Terminal" },
  { key = "<leader>ct", action = "Open chat panel", category = "Chat" },
  { key = "<C-CR>", action = "Send message", category = "Chat" },
  { key = "<leader>ca", action = "Open actions menu", category = "Actions" },
  { key = "<leader>cd", action = "Show diff for file", category = "Diff" },
  { key = "<leader>cm", action = "Switch model", category = "Model" },
  { key = "<leader>cy", action = "Accept hunk", category = "Diff" },
  { key = "<leader>cn", action = "Reject hunk", category = "Diff" },
  { key = "<leader>cY", action = "Accept all hunks", category = "Diff" },
  { key = "<leader>cN", action = "Reject all hunks", category = "Diff" },
  { key = "<leader>cx", action = "Stop operation", category = "Control" },
  { key = "<leader>ch", action = "Session history", category = "Session" },
  { key = "]c", action = "Next hunk", category = "Diff" },
  { key = "[c", action = "Previous hunk", category = "Diff" },
  { key = "<leader>cp", action = "Preview hunk", category = "Diff" },
  { key = "<leader>c?", action = "Show this help", category = "Help" },
}

--- Setup keymaps help
--- @param opts table|nil Configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

--- Get keymaps from config or use defaults
--- @return table[] Keymap entries
local function get_keymaps()
  local keymaps = {}

  -- Try to get from prism config
  local ok, prism_config = pcall(require, "prism.config")
  if ok then
    local cfg_keymaps = prism_config.get("keymaps")
    if cfg_keymaps then
      -- Map config keymaps to our format
      local mapping = {
        toggle = { action = "Toggle Claude terminal", category = "Terminal" },
        chat = { action = "Open chat panel", category = "Chat" },
        send = { action = "Send message", category = "Chat" },
        actions = { action = "Open actions menu", category = "Actions" },
        diff = { action = "Show diff for file", category = "Diff" },
        model = { action = "Switch model", category = "Model" },
        accept_hunk = { action = "Accept hunk", category = "Diff" },
        reject_hunk = { action = "Reject hunk", category = "Diff" },
        accept_all = { action = "Accept all hunks", category = "Diff" },
        reject_all = { action = "Reject all hunks", category = "Diff" },
        stop = { action = "Stop operation", category = "Control" },
        history = { action = "Session history", category = "Session" },
      }

      for name, key in pairs(cfg_keymaps) do
        if mapping[name] then
          table.insert(keymaps, {
            key = key,
            action = mapping[name].action,
            category = mapping[name].category,
          })
        end
      end

      -- Add navigation keymaps (these are usually hardcoded)
      table.insert(keymaps, { key = "]c", action = "Next hunk", category = "Diff" })
      table.insert(keymaps, { key = "[c", action = "Previous hunk", category = "Diff" })
      table.insert(keymaps, { key = "<leader>cp", action = "Preview hunk", category = "Diff" })
      table.insert(keymaps, { key = "<leader>c?", action = "Show this help", category = "Help" })
    end
  end

  -- Fall back to defaults if nothing found
  if #keymaps == 0 then
    keymaps = vim.deepcopy(default_keymaps)
  end

  -- Sort by category then by key
  table.sort(keymaps, function(a, b)
    if a.category ~= b.category then
      return a.category < b.category
    end
    return a.key < b.key
  end)

  return keymaps
end

--- Format keymaps for display
--- @return string[] Formatted lines
--- @return table[] Highlight info
local function format_keymaps()
  local lines = {}
  local highlights = {}
  local keymaps = get_keymaps()

  local current_category = nil

  for _, km in ipairs(keymaps) do
    -- Add category header
    if km.category ~= current_category then
      if current_category ~= nil then
        table.insert(lines, "") -- Blank line between categories
      end
      table.insert(lines, "  " .. km.category)
      table.insert(highlights, { line = #lines, hl_group = "PrismTitle" })
      table.insert(lines, string.rep("─", 50))
      table.insert(highlights, { line = #lines, hl_group = "PrismSeparator" })
      current_category = km.category
    end

    -- Format keymap line
    local key_display = string.format("  %-15s", km.key)
    local action_display = km.action
    table.insert(lines, key_display .. action_display)

    -- Highlight the key portion
    table.insert(highlights, {
      line = #lines,
      col_start = 2,
      col_end = 17,
      hl_group = "PrismModelName",
    })
  end

  -- Footer
  table.insert(lines, "")
  table.insert(lines, "  Press q or <Esc> to close")
  table.insert(highlights, { line = #lines, hl_group = "PrismKeyHint" })

  return lines, highlights
end

--- Show the keymaps help popup
function M.show()
  -- Close existing popup
  M.close()

  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    require("prism.ui.notify").error("nui.nvim is required for keymaps help")
    return
  end

  local lines, highlights = format_keymaps()

  -- Calculate dimensions
  local height = math.min(#lines + 2, 35)
  local width = config.width

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
        top = config.title,
        top_align = "center",
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

  -- Set content
  vim.api.nvim_buf_set_option(state.popup.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.popup.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.popup.bufnr, "modifiable", false)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    if hl.col_start then
      vim.api.nvim_buf_add_highlight(
        state.popup.bufnr, -1, hl.hl_group,
        hl.line - 1, hl.col_start, hl.col_end
      )
    else
      vim.api.nvim_buf_add_highlight(state.popup.bufnr, -1, hl.hl_group, hl.line - 1, 0, -1)
    end
  end

  -- Setup keymaps
  local bufnr = state.popup.bufnr
  vim.keymap.set("n", "q", function() M.close() end, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "?", function() M.close() end, { buffer = bufnr, nowait = true })

  -- Emit event
  local event_ok, event = pcall(require, "prism.event")
  if event_ok then
    event.emit("ui:keymaps_help:opened")
  end
end

--- Close the popup
function M.close()
  if state.popup then
    state.popup:unmount()
    state.popup = nil
  end
  state.is_open = false
end

--- Check if popup is open
--- @return boolean
function M.is_open()
  return state.is_open
end

--- Toggle the popup
function M.toggle()
  if state.is_open then
    M.close()
  else
    M.show()
  end
end

return M
