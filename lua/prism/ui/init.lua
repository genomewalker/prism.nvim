--- prism.nvim UI orchestrator
--- @module prism.ui

local M = {}

--- UI modules
M.highlights = require("prism.ui.highlights")
M.notify = require("prism.ui.notify")
M.chat = require("prism.ui.chat")
M.palette = require("prism.ui.palette")
M.model_picker = require("prism.ui.model_picker")
M.status = require("prism.ui.status")
M.spinner = require("prism.ui.spinner")
M.diff_popup = require("prism.ui.diff_popup")
M.keymaps_help = require("prism.ui.keymaps_help")

--- Configuration
local config = {
  border = "rounded",
  icons = true,
  blend = 0,
  width = 0.8,
  height = 0.8,
}

--- Check if nui.nvim is available
--- @return boolean
local function check_nui()
  local ok = pcall(require, "nui.popup")
  if not ok then
    M.notify.error("nui.nvim is required. Please install MunifTanjim/nui.nvim")
    return false
  end
  return true
end

--- Setup UI module
--- @param opts table|nil Configuration options
function M.setup(opts)
  opts = opts or {}

  -- Merge config
  config = vim.tbl_deep_extend("force", config, opts)

  -- Setup highlights
  M.highlights.setup(opts.highlights)

  -- Setup notification system
  M.notify.setup({
    enabled = opts.notifications ~= false,
    icons = opts.icons ~= false,
  })

  -- Setup chat panel
  M.chat.setup({
    width = opts.chat_width or 80,
    height = opts.chat_height or 30,
    border = config.border,
  })

  -- Setup palette
  M.palette.setup({
    width = opts.palette_width or 50,
    border = config.border,
    actions = opts.actions,
  })

  -- Setup model picker
  M.model_picker.setup({
    width = opts.model_picker_width or 45,
    border = config.border,
  })

  -- Setup status component
  M.status.setup({
    icon = opts.status_icon ~= false,
    connection = opts.status_connection ~= false,
    model = opts.status_model ~= false,
    cost = opts.status_cost ~= false,
    hunks = opts.status_hunks ~= false,
  })

  -- Setup spinner
  M.spinner.setup({
    interval = opts.spinner_interval or 80,
  })

  -- Setup diff popup
  M.diff_popup.setup({
    width = opts.diff_popup_width or 80,
    border = config.border,
  })

  -- Setup keymaps help
  M.keymaps_help.setup({
    width = opts.keymaps_help_width or 60,
    border = config.border,
  })

  -- Emit ready event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("ui:ready")
  end
end

--- Open chat panel
function M.open_chat()
  if not check_nui() then return end
  M.chat.open()
end

--- Open command palette
--- @param filter string|nil Filter string
function M.open_palette(filter)
  if not check_nui() then return end
  M.palette.open(filter)
end

--- Open model picker
function M.open_model_picker()
  if not check_nui() then return end
  M.model_picker.open()
end

--- Open action menu (alias for palette)
function M.open_action_menu()
  M.open_palette()
end

--- Toggle chat panel
function M.toggle_chat()
  if not check_nui() then return end
  M.chat.toggle()
end

--- Close all UI components
function M.close_all()
  M.chat.close()
  M.palette.close()
  M.model_picker.close()
  M.diff_popup.close()
  M.keymaps_help.close()
end

--- Show diff hunk preview
--- @param hunk table|nil Hunk to preview (nil for current)
function M.show_diff_preview(hunk)
  if not check_nui() then return end
  if hunk then
    M.diff_popup.show_hunk_preview(hunk)
  else
    M.diff_popup.show_current()
  end
end

--- Show keymaps help
function M.show_keymaps()
  if not check_nui() then return end
  M.keymaps_help.show()
end

--- Start spinner
--- @param callback function|nil
function M.start_spinner(callback)
  M.spinner.start(callback)
end

--- Stop spinner
function M.stop_spinner()
  M.spinner.stop()
end

--- Show an info notification
--- @param message string
function M.info(message)
  M.notify.info(message)
end

--- Show a warning notification
--- @param message string
function M.warn(message)
  M.notify.warn(message)
end

--- Show an error notification
--- @param message string
function M.error(message)
  M.notify.error(message)
end

--- Show a success notification
--- @param message string
function M.success(message)
  M.notify.success(message)
end

--- Get statusline component
--- @return table Lualine-compatible component
function M.statusline()
  return M.status.get_component()
end

--- Get status string
--- @return string
function M.get_status()
  return M.status.get()
end

--- Create a floating window with standard prism styling
--- @param opts table Window options
--- @return table|nil Popup object
function M.create_float(opts)
  if not check_nui() then return nil end

  local Popup = require("nui.popup")

  opts = vim.tbl_deep_extend("force", {
    enter = true,
    focusable = true,
    border = {
      style = config.border,
    },
    position = "50%",
    size = {
      width = opts.width or "60%",
      height = opts.height or "60%",
    },
    win_options = {
      winblend = config.blend,
      winhighlight = "Normal:PrismNormal,FloatBorder:PrismBorder,FloatTitle:PrismTitle",
    },
  }, opts)

  local popup = Popup(opts)
  return popup
end

--- Show a confirmation dialog
--- @param message string Message to show
--- @param callback function Callback with boolean result
function M.confirm(message, callback)
  vim.ui.select({ "Yes", "No" }, {
    prompt = message,
  }, function(choice)
    callback(choice == "Yes")
  end)
end

--- Show an input dialog
--- @param prompt string Prompt message
--- @param default string|nil Default value
--- @param callback function Callback with input value
function M.input(prompt, default, callback)
  vim.ui.input({
    prompt = prompt,
    default = default or "",
  }, callback)
end

return M
