--- prism.nvim actions module
--- Code action framework with prompt templates
--- @module prism.actions

local M = {}

local builtin = require("prism.actions.builtin")
local config = require("prism.config")
local event = require("prism.event")

--- Registered actions
--- @type table<string, table>
local actions = {}

--- Initialize with builtin actions
local function init()
  for name, spec in pairs(builtin.all()) do
    actions[name] = spec
  end
end

--- Setup actions with config
--- @param opts table|nil Configuration options
function M.setup(opts)
  opts = opts or {}

  -- Load builtins
  init()

  -- Register custom actions from config
  if opts.custom_actions then
    for name, spec in pairs(opts.custom_actions) do
      M.register(name, spec)
    end
  end
end

--- Register a custom action
--- @param name string Action name
--- @param spec table Action specification
--- @return boolean success
function M.register(name, spec)
  if not spec.prompt_template then
    vim.notify("[prism.actions] Action must have prompt_template", vim.log.levels.ERROR)
    return false
  end

  actions[name] = vim.tbl_extend("force", {
    name = name,
    icon = "",
    description = "",
    requires_selection = false,
    requires_input = false,
    output = "floating",
  }, spec)

  return true
end

--- Unregister an action
--- @param name string Action name
--- @return boolean success
function M.unregister(name)
  if actions[name] then
    actions[name] = nil
    return true
  end
  return false
end

--- Get action by name
--- @param name string Action name
--- @return table|nil Action spec
function M.get(name)
  return actions[name]
end

--- List all available actions
--- @return table[] Actions with names
function M.list()
  local result = {}
  for name, spec in pairs(actions) do
    table.insert(result, vim.tbl_extend("force", { id = name }, spec))
  end

  -- Sort by name
  table.sort(result, function(a, b)
    return a.name < b.name
  end)

  return result
end

--- Get visual selection
--- @return string|nil selection, number start_line, number end_line
local function get_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    -- Not in visual mode, check for marks
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")

    if start_pos[2] == 0 and end_pos[2] == 0 then
      return nil, 0, 0
    end

    local lines = vim.fn.getline(start_pos[2], end_pos[2])
    if type(lines) == "string" then
      lines = { lines }
    end
    return table.concat(lines, "\n"), start_pos[2], end_pos[2]
  end

  -- In visual mode
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")

  -- Normalize positions
  if start_pos[2] > end_pos[2] then
    start_pos, end_pos = end_pos, start_pos
  end

  local lines = vim.fn.getline(start_pos[2], end_pos[2])
  if type(lines) == "string" then
    lines = { lines }
  end

  return table.concat(lines, "\n"), start_pos[2], end_pos[2]
end

--- Build prompt from template
--- @param template string Prompt template
--- @param context table Context variables
--- @return string Rendered prompt
local function render_template(template, context)
  local result = template

  for key, value in pairs(context) do
    result = result:gsub("{" .. key .. "}", value or "")
  end

  return result
end

--- Run an action
--- @param action_name string Action name
--- @param opts table|nil Options {selection, file, filetype, input, context}
--- @return table|nil Result or nil on error
function M.run(action_name, opts)
  opts = opts or {}

  local action = actions[action_name]
  if not action then
    vim.notify("[prism.actions] Unknown action: " .. action_name, vim.log.levels.ERROR)
    return nil
  end

  -- Get selection if needed
  local selection = opts.selection
  local start_line, end_line = 0, 0
  if not selection and action.requires_selection then
    selection, start_line, end_line = get_selection()
    if not selection or selection == "" then
      vim.notify("[prism.actions] Action requires a selection", vim.log.levels.WARN)
      return nil
    end
  end

  -- Get file info
  local file = opts.file or vim.fn.expand("%:p")
  local filetype = opts.filetype or vim.bo.filetype or "text"
  local relative_file = vim.fn.fnamemodify(file, ":~:.")

  -- Handle input requirement
  local input = opts.input or ""
  if action.requires_input and not opts.input then
    local prompt = action.input_prompt or "Input:"
    input = vim.fn.input(prompt .. " ")
    if input == "" then
      return nil
    end
  end

  -- Build context
  local context = vim.tbl_extend("force", {
    selection = selection or "",
    file = relative_file,
    filetype = filetype,
    input = input,
    context = opts.context or "",
  }, opts.extra_context or {})

  -- Render prompt
  local prompt = render_template(action.prompt_template, context)

  -- Emit event
  event.emit("action:started", {
    action = action_name,
    prompt = prompt,
    output_type = action.output,
    start_line = start_line,
    end_line = end_line,
  })

  return {
    action = action_name,
    prompt = prompt,
    output_type = action.output,
    start_line = start_line,
    end_line = end_line,
    file = file,
    filetype = filetype,
    selection = selection,
  }
end

--- Open action picker/menu
--- @param opts table|nil Options
function M.menu(opts)
  opts = opts or {}

  local items = M.list()
  local ui_config = config.get("ui") or {}

  -- Format items for picker
  local formatted = {}
  for _, item in ipairs(items) do
    table.insert(formatted, {
      display = string.format("%s %s", item.icon or "", item.name),
      value = item.id,
      description = item.description or "",
    })
  end

  -- Use vim.ui.select
  vim.ui.select(formatted, {
    prompt = "Select Action:",
    format_item = function(item)
      if item.description and item.description ~= "" then
        return item.display .. " - " .. item.description
      end
      return item.display
    end,
  }, function(choice)
    if choice then
      local result = M.run(choice.value, opts)
      if result and opts.on_select then
        opts.on_select(result)
      end
    end
  end)
end

--- Get action names for completion
--- @return string[] Action names
function M.complete()
  local names = {}
  for name, _ in pairs(actions) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Builtin actions access
M.builtin = builtin

-- Initialize on load
init()

return M
