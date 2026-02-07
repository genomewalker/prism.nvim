--- prism.nvim command palette
--- @module prism.ui.palette

local M = {}

--- State
local state = {
  menu = nil,
  is_open = false,
}

--- Default actions
local default_actions = {
  {
    id = "send_selection",
    label = "Send Selection",
    icon = "",
    hint = "Send visual selection to Claude",
    action = "send_selection",
  },
  {
    id = "send_file",
    label = "Send File",
    icon = "",
    hint = "Send current file to Claude",
    action = "send_file",
  },
  {
    id = "ask",
    label = "Ask",
    icon = "",
    hint = "Ask Claude a question",
    action = "ask",
  },
  {
    id = "explain",
    label = "Explain",
    icon = "",
    hint = "Explain selected code",
    action = "explain",
  },
  {
    id = "fix",
    label = "Fix",
    icon = "",
    hint = "Fix errors in code",
    action = "fix",
  },
  {
    id = "refactor",
    label = "Refactor",
    icon = "",
    hint = "Refactor selected code",
    action = "refactor",
  },
  {
    id = "optimize",
    label = "Optimize",
    icon = "",
    hint = "Optimize for performance",
    action = "optimize",
  },
  {
    id = "test",
    label = "Test",
    icon = "",
    hint = "Generate tests",
    action = "test",
  },
  {
    id = "document",
    label = "Document",
    icon = "",
    hint = "Generate documentation",
    action = "document",
  },
  {
    id = "review",
    label = "Review",
    icon = "",
    hint = "Code review",
    action = "review",
  },
  {
    id = "chat",
    label = "Open Chat",
    icon = "󰭻",
    hint = "Open chat panel",
    action = "chat",
  },
  {
    id = "model",
    label = "Switch Model",
    icon = "󰚩",
    hint = "Change Claude model",
    action = "model",
  },
  {
    id = "session",
    label = "Sessions",
    icon = "",
    hint = "Manage sessions",
    action = "session",
  },
  {
    id = "diff",
    label = "View Diff",
    icon = "",
    hint = "Show pending changes",
    action = "diff",
  },
  {
    id = "accept_all",
    label = "Accept All",
    icon = "",
    hint = "Accept all changes",
    action = "accept_all",
  },
  {
    id = "reject_all",
    label = "Reject All",
    icon = "",
    hint = "Reject all changes",
    action = "reject_all",
  },
}

--- Configuration
local config = {
  width = 50,
  border = "rounded",
  title = " Prism Actions ",
  actions = default_actions,
}

--- Format a menu item
--- @param item table Action item
--- @return table NuiMenu.item
local function format_item(item)
  local Menu = require("nui.menu")
  local text = string.format("%s  %s", item.icon, item.label)
  return Menu.item(text, { id = item.id, action = item.action, hint = item.hint })
end

--- Setup palette
--- @param opts table|nil Configuration options
function M.setup(opts)
  if opts then
    config = vim.tbl_deep_extend("force", config, opts)
  end
end

--- Add a custom action
--- @param action table Action definition
function M.add_action(action)
  table.insert(config.actions, action)
end

--- Remove an action by id
--- @param id string Action id
function M.remove_action(id)
  for i, action in ipairs(config.actions) do
    if action.id == id then
      table.remove(config.actions, i)
      return true
    end
  end
  return false
end

--- Open the command palette
--- @param filter string|nil Filter actions by prefix
function M.open(filter)
  if state.is_open then
    M.close()
    return
  end

  local ok, Menu = pcall(require, "nui.menu")
  if not ok then
    require("prism.ui.notify").error("nui.nvim is required for palette UI")
    return
  end

  -- Filter actions if specified
  local actions = config.actions
  if filter and filter ~= "" then
    filter = filter:lower()
    actions = vim.tbl_filter(function(a)
      return a.label:lower():find(filter, 1, true) or a.id:lower():find(filter, 1, true)
    end, actions)
  end

  -- Build menu items
  local lines = {}
  for _, action in ipairs(actions) do
    table.insert(lines, format_item(action))
  end

  if #lines == 0 then
    require("prism.ui.notify").info("No matching actions")
    return
  end

  -- Create menu
  state.menu = Menu({
    position = "50%",
    size = {
      width = config.width,
      height = math.min(#lines + 2, 20),
    },
    border = {
      style = config.border,
      text = {
        top = config.title,
        top_align = "center",
      },
    },
    win_options = {
      winblend = 0,
      winhighlight = "Normal:PrismNormal,FloatBorder:PrismBorder,FloatTitle:PrismTitle,CursorLine:PrismCursorLine",
    },
  }, {
    lines = lines,
    max_width = config.width,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "<Esc>", "<C-c>", "q" },
      submit = { "<CR>", "<Space>" },
    },
    on_close = function()
      state.is_open = false
      state.menu = nil
    end,
    on_submit = function(item)
      state.is_open = false
      state.menu = nil

      -- Execute action
      if item.action then
        M.execute_action(item.action, item.id)
      end
    end,
  })

  state.menu:mount()
  state.is_open = true

  -- Add hint line at bottom
  vim.schedule(function()
    if state.menu and state.menu.winid then
      -- Show hint for selected item
      local function update_hint()
        if not state.menu or not state.menu.winid then return end
        local node = state.menu.tree:get_node()
        if node and node.hint then
          vim.api.nvim_echo({ { node.hint, "PrismPaletteHint" } }, false, {})
        end
      end

      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = state.menu.bufnr,
        callback = update_hint,
      })

      update_hint()
    end
  end)

  -- Emit event
  local events_ok, event = pcall(require, "prism.event")
  if events_ok then
    event.emit("ui:palette:opened")
  end
end

--- Close the palette
function M.close()
  if state.menu then
    state.menu:unmount()
    state.menu = nil
  end
  state.is_open = false
end

--- Execute an action
--- @param action string Action name
--- @param id string Action id
function M.execute_action(action, id)
  -- Emit event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("action:execute", { action = action, id = id })
  end

  -- Handle built-in actions
  if action == "chat" then
    require("prism.ui.chat").toggle()
  elseif action == "model" then
    require("prism.ui.model_picker").open()
  else
    -- Delegate to actions module if available
    local actions_ok, actions = pcall(require, "prism.actions")
    if actions_ok and actions.execute then
      actions.execute(action)
    else
      require("prism.ui.notify").info("Action: " .. action)
    end
  end
end

--- Check if palette is open
--- @return boolean
function M.is_open()
  return state.is_open
end

--- Get all actions
--- @return table
function M.get_actions()
  return vim.deepcopy(config.actions)
end

return M
