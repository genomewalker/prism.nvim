--- prism.nvim statusline component
--- @module prism.ui.status

local M = {}

--- State
local state = {
  connected = false,
  model = nil,
  cost = 0.00,
  pending_hunks = 0,
  processing = false,
  session = nil,
}

--- Icons
local icons = {
  prism = "󰚩",
  connected = "",
  disconnected = "",
  processing = "",
  diff = "",
  cost = "$",
}

--- Configuration
local config = {
  icon = true,
  connection = true,
  model = true,
  cost = true,
  hunks = true,
  separator = " ",
}

--- Setup status component
--- @param opts table|nil Configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  -- Listen for events
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.on("mcp:connected", function()
      state.connected = true
    end)

    event.on("mcp:disconnected", function()
      state.connected = false
    end)

    event.on("model:changed", function(data)
      state.model = data.id
    end)

    event.on("cost:updated", function(data)
      state.cost = data.total or 0
    end)

    event.on("diff:created", function(data)
      state.pending_hunks = data.hunk_count or 0
    end)

    event.on("diff:hunk:accepted", function()
      state.pending_hunks = math.max(0, state.pending_hunks - 1)
    end)

    event.on("diff:hunk:rejected", function()
      state.pending_hunks = math.max(0, state.pending_hunks - 1)
    end)

    event.on("diff:all:accepted", function()
      state.pending_hunks = 0
    end)

    event.on("diff:all:rejected", function()
      state.pending_hunks = 0
    end)

    event.on("processing:started", function()
      state.processing = true
    end)

    event.on("processing:finished", function()
      state.processing = false
    end)

    event.on("session:changed", function(data)
      state.session = data.id
    end)
  end
end

--- Update state values
--- @param updates table State updates
function M.update(updates)
  state = vim.tbl_deep_extend("force", state, updates)
end

--- Get raw state
--- @return table
function M.state()
  return vim.deepcopy(state)
end

--- Format cost for display
--- @param cost number
--- @return string
local function format_cost(cost)
  if cost < 0.01 then
    return string.format("$%.3f", cost)
  elseif cost < 1 then
    return string.format("$%.2f", cost)
  else
    return string.format("$%.2f", cost)
  end
end

--- Get cost highlight based on amount
--- @param cost number
--- @return string
local function get_cost_highlight(cost)
  if cost < 0.10 then
    return "PrismCostLow"
  elseif cost < 1.00 then
    return "PrismCostMed"
  else
    return "PrismCostHigh"
  end
end

--- Get the status string
--- @return string
function M.get()
  local parts = {}

  -- Prism icon
  if config.icon then
    table.insert(parts, icons.prism)
  end

  -- Connection status
  if config.connection then
    if state.processing then
      table.insert(parts, icons.processing)
    elseif state.connected then
      table.insert(parts, icons.connected)
    else
      table.insert(parts, icons.disconnected)
    end
  end

  -- Model
  if config.model and state.model then
    table.insert(parts, state.model)
  end

  -- Cost
  if config.cost and state.cost > 0 then
    table.insert(parts, format_cost(state.cost))
  end

  -- Pending hunks
  if config.hunks and state.pending_hunks > 0 then
    table.insert(parts, icons.diff .. " " .. state.pending_hunks)
  end

  return table.concat(parts, config.separator)
end

--- Get lualine component configuration
--- @return table Lualine component config
function M.get_component()
  return {
    function()
      return M.get()
    end,
    cond = function()
      -- Only show when we have something to display
      return state.connected or state.model ~= nil or state.cost > 0 or state.pending_hunks > 0
    end,
    color = function()
      if state.processing then
        return { fg = "#61afef" }
      elseif state.connected then
        return { fg = "#98c379" }
      else
        return { fg = "#e06c75" }
      end
    end,
  }
end

--- Get status with highlights (for custom statusline integration)
--- @return table[] Array of {text, highlight} pairs
function M.get_highlighted()
  local result = {}

  -- Prism icon
  if config.icon then
    table.insert(result, { icons.prism .. " ", "PrismActionIcon" })
  end

  -- Connection status
  if config.connection then
    if state.processing then
      table.insert(result, { icons.processing .. " ", "PrismStatusProcessing" })
    elseif state.connected then
      table.insert(result, { icons.connected .. " ", "PrismStatusConnected" })
    else
      table.insert(result, { icons.disconnected .. " ", "PrismStatusDisconnected" })
    end
  end

  -- Model
  if config.model and state.model then
    local model_hl = "PrismModel" .. state.model:sub(1, 1):upper() .. state.model:sub(2)
    table.insert(result, { state.model .. " ", model_hl })
  end

  -- Cost
  if config.cost and state.cost > 0 then
    table.insert(result, { format_cost(state.cost) .. " ", get_cost_highlight(state.cost) })
  end

  -- Pending hunks
  if config.hunks and state.pending_hunks > 0 then
    table.insert(result, { icons.diff .. " " .. state.pending_hunks, "PrismDiffChangeSign" })
  end

  return result
end

--- Set connected state
--- @param connected boolean
function M.set_connected(connected)
  state.connected = connected
end

--- Set current model
--- @param model string|nil
function M.set_model(model)
  state.model = model
end

--- Set cost
--- @param cost number
function M.set_cost(cost)
  state.cost = cost
end

--- Set pending hunks count
--- @param count number
function M.set_hunks(count)
  state.pending_hunks = count
end

--- Set processing state
--- @param processing boolean
function M.set_processing(processing)
  state.processing = processing
end

return M
