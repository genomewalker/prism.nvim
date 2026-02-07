--- prism.nvim cost tracking module
--- Track and display API usage costs
--- @module prism.cost

local M = {}

local pricing = require("prism.cost.pricing")
local event = require("prism.event")

--- Cost tracking state
--- @type table
local state = {
  session_costs = {}, -- {action_name, model, input_tokens, output_tokens, cost, timestamp}
  total_input_tokens = 0,
  total_output_tokens = 0,
  total_cost = 0,
}

--- Track a cost event
--- @param evt table Cost event {model, input_tokens, output_tokens, action?}
function M.track(evt)
  if not evt.model or not evt.input_tokens or not evt.output_tokens then
    return
  end

  local cost = pricing.calculate(evt.model, evt.input_tokens, evt.output_tokens)

  local entry = {
    action = evt.action or "unknown",
    model = evt.model,
    input_tokens = evt.input_tokens,
    output_tokens = evt.output_tokens,
    cost = cost,
    timestamp = vim.loop.hrtime() / 1e6,
  }

  table.insert(state.session_costs, entry)
  state.total_input_tokens = state.total_input_tokens + evt.input_tokens
  state.total_output_tokens = state.total_output_tokens + evt.output_tokens
  state.total_cost = state.total_cost + cost

  -- Emit cost updated event
  event.emit(event.events.COST_UPDATED, {
    entry = entry,
    session_total = state.total_cost,
    session_input_tokens = state.total_input_tokens,
    session_output_tokens = state.total_output_tokens,
  })
end

--- Get total session cost
--- @return number Total cost in USD
function M.get_session_cost()
  return state.total_cost
end

--- Get session token counts
--- @return number input_tokens
--- @return number output_tokens
function M.get_session_tokens()
  return state.total_input_tokens, state.total_output_tokens
end

--- Get costs grouped by action
--- @return table<string, {count: number, cost: number, input: number, output: number}>
function M.get_action_costs()
  local actions = {}

  for _, entry in ipairs(state.session_costs) do
    local action = entry.action
    if not actions[action] then
      actions[action] = { count = 0, cost = 0, input = 0, output = 0 }
    end
    actions[action].count = actions[action].count + 1
    actions[action].cost = actions[action].cost + entry.cost
    actions[action].input = actions[action].input + entry.input_tokens
    actions[action].output = actions[action].output + entry.output_tokens
  end

  return actions
end

--- Get costs grouped by model
--- @return table<string, {count: number, cost: number, input: number, output: number}>
function M.get_model_costs()
  local models = {}

  for _, entry in ipairs(state.session_costs) do
    local model = pricing.normalize_model(entry.model)
    if not models[model] then
      models[model] = { count = 0, cost = 0, input = 0, output = 0 }
    end
    models[model].count = models[model].count + 1
    models[model].cost = models[model].cost + entry.cost
    models[model].input = models[model].input + entry.input_tokens
    models[model].output = models[model].output + entry.output_tokens
  end

  return models
end

--- Get all cost entries
--- @return table[] Cost entries
function M.get_entries()
  return vim.deepcopy(state.session_costs)
end

--- Reset cost tracking
function M.reset()
  state.session_costs = {}
  state.total_input_tokens = 0
  state.total_output_tokens = 0
  state.total_cost = 0
end

--- Format cost as string
--- @param cost number Cost in USD
--- @return string Formatted cost string
function M.format(cost)
  if cost < 0.01 then
    return string.format("$%.4f", cost)
  elseif cost < 1 then
    return string.format("$%.3f", cost)
  else
    return string.format("$%.2f", cost)
  end
end

--- Format token count
--- @param tokens number Token count
--- @return string Formatted token string
function M.format_tokens(tokens)
  if tokens < 1000 then
    return tostring(tokens)
  elseif tokens < 1000000 then
    return string.format("%.1fK", tokens / 1000)
  else
    return string.format("%.2fM", tokens / 1000000)
  end
end

--- Get cost summary string
--- @return string Summary of session costs
function M.summary()
  local cost_str = M.format(state.total_cost)
  local input_str = M.format_tokens(state.total_input_tokens)
  local output_str = M.format_tokens(state.total_output_tokens)
  return string.format("%s (%s in / %s out)", cost_str, input_str, output_str)
end

--- Show cost information in a notification
function M.show()
  local summary = M.summary()
  local lines = {
    "󰚩 Prism Cost Tracking",
    string.rep("─", 30),
    "Session: " .. summary,
    "",
    "Model breakdown:",
  }

  local model_costs = M.get_model_costs()
  for model, data in pairs(model_costs) do
    table.insert(lines, string.format("  %s: %s (%d calls)", model, M.format(data.cost), data.calls))
  end

  if vim.tbl_isempty(model_costs) then
    table.insert(lines, "  No API calls tracked yet")
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Export state for session persistence
--- @return table Serializable state
function M.export()
  return vim.deepcopy(state)
end

--- Import state from session
--- @param data table Previously exported state
function M.import(data)
  if not data then
    return
  end
  state.session_costs = data.session_costs or {}
  state.total_input_tokens = data.total_input_tokens or 0
  state.total_output_tokens = data.total_output_tokens or 0
  state.total_cost = data.total_cost or 0
end

--- Pricing module access
M.pricing = pricing

return M
