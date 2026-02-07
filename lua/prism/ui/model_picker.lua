--- prism.nvim model picker
--- @module prism.ui.model_picker

local M = {}

--- State
local state = {
  menu = nil,
  is_open = false,
  current_model = nil,
}

--- Available models with metadata
local models = {
  {
    id = "opus",
    name = "Claude Opus 4",
    icon = "󰚩",
    description = "Most capable, best for complex tasks",
    cost = "$$$",
    cost_level = "high",
    model_id = "claude-opus-4-5",
  },
  {
    id = "sonnet",
    name = "Claude Sonnet 4",
    icon = "󰚩",
    description = "Balanced performance and speed",
    cost = "$$",
    cost_level = "med",
    model_id = "claude-sonnet-4-5-20250929",
  },
  {
    id = "haiku",
    name = "Claude Haiku",
    icon = "󰚩",
    description = "Fastest, most economical",
    cost = "$",
    cost_level = "low",
    model_id = "claude-haiku-4-5-20251001",
  },
}

--- Configuration
local config = {
  width = 45,
  border = "rounded",
  title = " Select Model ",
}

--- Get highlight for cost level
--- @param level string
--- @return string
local function get_cost_highlight(level)
  if level == "high" then
    return "PrismCostHigh"
  elseif level == "med" then
    return "PrismCostMed"
  else
    return "PrismCostLow"
  end
end

--- Setup model picker
--- @param opts table|nil Configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

--- Open the model picker
function M.open()
  if state.is_open then
    M.close()
    return
  end

  local ok, Menu = pcall(require, "nui.menu")
  if not ok then
    require("prism.ui.notify").error("nui.nvim is required for model picker")
    return
  end

  local NuiText = require("nui.text")
  local NuiLine = require("nui.line")

  -- Build menu items
  local lines = {}
  for _, model in ipairs(models) do
    local line = NuiLine()

    -- Icon
    line:append(" " .. model.icon .. " ", "PrismActionIcon")

    -- Name (with highlight if current)
    local name_hl = "PrismModel" .. model.id:sub(1, 1):upper() .. model.id:sub(2)
    if state.current_model == model.id then
      line:append(model.name .. " ", name_hl)
      line:append("", "PrismStatusConnected")
    else
      line:append(model.name .. " ", name_hl)
    end

    -- Cost indicator
    local cost_hl = get_cost_highlight(model.cost_level)
    line:append(" " .. model.cost, cost_hl)

    local item = Menu.item(line, {
      id = model.id,
      model_id = model.model_id,
      name = model.name,
      description = model.description,
    })
    table.insert(lines, item)
  end

  -- Create menu
  state.menu = Menu({
    position = "50%",
    size = {
      width = config.width,
      height = #lines + 2,
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
      M.select_model(item.id, item.model_id, item.name)
    end,
  })

  state.menu:mount()
  state.is_open = true

  -- Show description on cursor move
  vim.schedule(function()
    if state.menu and state.menu.bufnr then
      local function update_description()
        if not state.menu or not state.menu.winid then return end
        local node = state.menu.tree:get_node()
        if node and node.description then
          vim.api.nvim_echo({ { node.description, "PrismMuted" } }, false, {})
        end
      end

      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = state.menu.bufnr,
        callback = update_description,
      })

      update_description()
    end
  end)

  -- Emit event
  local events_ok, event = pcall(require, "prism.event")
  if events_ok then
    event.emit("ui:model_picker:opened")
  end
end

--- Close the model picker
function M.close()
  if state.menu then
    state.menu:unmount()
    state.menu = nil
  end
  state.is_open = false
end

--- Select a model
--- @param id string Short model id (opus, sonnet, haiku)
--- @param model_id string Full model identifier
--- @param name string Display name
function M.select_model(id, model_id, name)
  local previous = state.current_model
  state.current_model = id

  require("prism.ui.notify").success("Switched to " .. name)

  -- Emit event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("model:changed", {
      id = id,
      model_id = model_id,
      name = name,
      previous = previous,
    })
  end
end

--- Get current model
--- @return string|nil
function M.get_current()
  return state.current_model
end

--- Set current model (without triggering events)
--- @param id string Model id
function M.set_current(id)
  state.current_model = id
end

--- Get model info by id
--- @param id string Model id
--- @return table|nil
function M.get_model_info(id)
  for _, model in ipairs(models) do
    if model.id == id then
      return vim.deepcopy(model)
    end
  end
  return nil
end

--- Get all available models
--- @return table
function M.get_models()
  return vim.deepcopy(models)
end

--- Check if picker is open
--- @return boolean
function M.is_open()
  return state.is_open
end

return M
