--- prism.nvim pricing module
--- Model pricing data and cost calculation
--- @module prism.cost.pricing

local M = {}

--- Pricing per million tokens (USD)
--- @type table<string, {input: number, output: number}>
M.pricing = {
  -- Claude 4 models
  ["claude-opus-4"] = { input = 15.0, output = 75.0 },
  ["claude-sonnet-4"] = { input = 3.0, output = 15.0 },
  ["claude-haiku"] = { input = 0.25, output = 1.25 },
  -- Claude 3.5 models (legacy)
  ["claude-3-5-sonnet"] = { input = 3.0, output = 15.0 },
  ["claude-3-5-haiku"] = { input = 0.25, output = 1.25 },
  -- Claude 3 models (legacy)
  ["claude-3-opus"] = { input = 15.0, output = 75.0 },
  ["claude-3-sonnet"] = { input = 3.0, output = 15.0 },
  ["claude-3-haiku"] = { input = 0.25, output = 1.25 },
}

--- Normalize model name to match pricing keys
--- @param model string Raw model name from API
--- @return string Normalized model name
function M.normalize_model(model)
  if not model then
    return "claude-sonnet-4"
  end

  local lower = model:lower()

  -- Match claude-4/claude-opus-4 variants
  if lower:match("opus%-4") or lower:match("claude%-4.*opus") then
    return "claude-opus-4"
  end
  if lower:match("sonnet%-4") or lower:match("claude%-4.*sonnet") then
    return "claude-sonnet-4"
  end
  if lower:match("haiku") then
    return "claude-haiku"
  end

  -- Match claude-3.5 variants
  if lower:match("3[._%-]5.*sonnet") or lower:match("sonnet.*3[._%-]5") then
    return "claude-3-5-sonnet"
  end
  if lower:match("3[._%-]5.*haiku") or lower:match("haiku.*3[._%-]5") then
    return "claude-3-5-haiku"
  end

  -- Match claude-3 variants
  if lower:match("3.*opus") or lower:match("opus.*3") then
    return "claude-3-opus"
  end
  if lower:match("3.*sonnet") or lower:match("sonnet.*3") then
    return "claude-3-sonnet"
  end
  if lower:match("3.*haiku") or lower:match("haiku.*3") then
    return "claude-3-haiku"
  end

  -- Default fallback
  if lower:match("opus") then
    return "claude-opus-4"
  end
  if lower:match("sonnet") then
    return "claude-sonnet-4"
  end
  if lower:match("haiku") then
    return "claude-haiku"
  end

  return "claude-sonnet-4"
end

--- Calculate cost for token usage
--- @param model string Model name
--- @param input_tokens number Number of input tokens
--- @param output_tokens number Number of output tokens
--- @return number Total cost in USD
function M.calculate(model, input_tokens, output_tokens)
  local normalized = M.normalize_model(model)
  local prices = M.pricing[normalized]

  if not prices then
    prices = M.pricing["claude-sonnet-4"]
  end

  local input_cost = (input_tokens / 1000000) * prices.input
  local output_cost = (output_tokens / 1000000) * prices.output

  return input_cost + output_cost
end

--- Get pricing for a model
--- @param model string Model name
--- @return table|nil Pricing table {input, output} or nil
function M.get_pricing(model)
  local normalized = M.normalize_model(model)
  return M.pricing[normalized]
end

--- Add or update pricing for a model
--- @param model string Model name
--- @param input number Input price per million tokens
--- @param output number Output price per million tokens
function M.set_pricing(model, input, output)
  M.pricing[model] = { input = input, output = output }
end

return M
