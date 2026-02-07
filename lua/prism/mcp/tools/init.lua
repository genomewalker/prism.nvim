--- prism.nvim MCP Tool Registry and Dispatcher
--- @module prism.mcp.tools

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Registered tools
--- @type table<string, table>
local tools = {}

--- Tool execution state for blocking tools
--- @type table<string, table>
local pending_executions = {}

--- Register a tool
--- @param name string Tool name
--- @param definition table Tool definition with schema and handler
function M.register(name, definition)
  if not definition.inputSchema then
    error(string.format("Tool '%s' must have an inputSchema", name))
  end
  if not definition.handler then
    error(string.format("Tool '%s' must have a handler function", name))
  end

  tools[name] = {
    name = name,
    description = definition.description or "",
    inputSchema = definition.inputSchema,
    handler = definition.handler,
    blocking = definition.blocking or false,
  }

  util.log.debug("Registered MCP tool: " .. name)
end

--- Unregister a tool
--- @param name string Tool name
function M.unregister(name)
  tools[name] = nil
end

--- Get tool definition
--- @param name string Tool name
--- @return table|nil Tool definition
function M.get(name)
  return tools[name]
end

--- List all registered tools
--- @return table[] Tool definitions for MCP protocol
function M.list()
  local result = {}
  for name, tool in pairs(tools) do
    table.insert(result, {
      name = name,
      description = tool.description,
      inputSchema = tool.inputSchema,
    })
  end
  return result
end

--- Execute a tool
--- @param name string Tool name
--- @param params table Tool parameters
--- @param call_id string|nil Optional call ID for tracking
--- @return table Result with { content, isError }
function M.execute(name, params, call_id)
  local tool = tools[name]
  if not tool then
    return {
      content = { { type = "text", text = "Unknown tool: " .. name } },
      isError = true,
    }
  end

  call_id = call_id or util.uuid_v4()

  event.emit("mcp:tool_call", {
    tool = name,
    params = params,
    call_id = call_id,
  })

  local ok, result = pcall(tool.handler, params, call_id)

  if not ok then
    util.log.error("Tool execution failed: " .. name, { error = result })
    event.emit("mcp:tool_error", {
      tool = name,
      call_id = call_id,
      error = result,
    })
    return {
      content = { { type = "text", text = "Tool error: " .. tostring(result) } },
      isError = true,
    }
  end

  event.emit("mcp:tool_result", {
    tool = name,
    call_id = call_id,
    result = result,
  })

  return result
end

--- Execute a blocking tool (returns a promise-like structure)
--- @param name string Tool name
--- @param params table Tool parameters
--- @param call_id string Call ID for tracking
--- @return table Pending execution with resolve/reject methods
function M.execute_blocking(name, params, call_id)
  local tool = tools[name]
  if not tool or not tool.blocking then
    return M.execute(name, params, call_id)
  end

  local pending = {
    call_id = call_id,
    tool = name,
    params = params,
    status = "pending",
    result = nil,
    callbacks = {},
  }

  pending_executions[call_id] = pending

  -- Start the tool execution
  local ok, initial = pcall(tool.handler, params, call_id)
  if not ok then
    pending.status = "error"
    pending.result = {
      content = { { type = "text", text = "Tool error: " .. tostring(initial) } },
      isError = true,
    }
    pending_executions[call_id] = nil
    return pending.result
  end

  -- If handler returned immediately, it's not actually blocking
  if initial and initial.content then
    pending.status = "completed"
    pending.result = initial
    pending_executions[call_id] = nil
    return initial
  end

  -- Return pending state
  return pending
end

--- Resolve a pending blocking execution
--- @param call_id string Call ID
--- @param result any Result to resolve with
function M.resolve(call_id, result)
  local pending = pending_executions[call_id]
  if not pending then
    util.log.warn("No pending execution for call_id: " .. call_id)
    return
  end

  pending.status = "completed"
  pending.result = {
    content = { { type = "text", text = util.json_encode(result) or tostring(result) } },
    isError = false,
  }

  -- Call any registered callbacks
  for _, cb in ipairs(pending.callbacks) do
    pcall(cb, pending.result)
  end

  pending_executions[call_id] = nil

  event.emit("mcp:tool_resolved", {
    tool = pending.tool,
    call_id = call_id,
    result = result,
  })
end

--- Reject a pending blocking execution
--- @param call_id string Call ID
--- @param reason string Rejection reason
function M.reject(call_id, reason)
  local pending = pending_executions[call_id]
  if not pending then
    util.log.warn("No pending execution for call_id: " .. call_id)
    return
  end

  pending.status = "rejected"
  pending.result = {
    content = { { type = "text", text = reason or "Rejected by user" } },
    isError = true,
  }

  -- Call any registered callbacks
  for _, cb in ipairs(pending.callbacks) do
    pcall(cb, pending.result)
  end

  pending_executions[call_id] = nil

  event.emit("mcp:tool_rejected", {
    tool = pending.tool,
    call_id = call_id,
    reason = reason,
  })
end

--- Get pending execution by call_id
--- @param call_id string Call ID
--- @return table|nil Pending execution
function M.get_pending(call_id)
  return pending_executions[call_id]
end

--- List all pending executions
--- @return table<string, table> Pending executions
function M.list_pending()
  return vim.deepcopy(pending_executions)
end

--- Register callback for when a blocking execution completes
--- @param call_id string Call ID
--- @param callback function Callback function(result)
function M.on_complete(call_id, callback)
  local pending = pending_executions[call_id]
  if not pending then
    return
  end

  if pending.status ~= "pending" then
    -- Already completed
    callback(pending.result)
    return
  end

  table.insert(pending.callbacks, callback)
end

--- Load all built-in tools
function M.load_builtins()
  local builtin_tools = {
    "open_file",
    "open_diff",
    "get_selection",
    "get_editors",
    "get_workspace",
    "get_diagnostics",
    "check_dirty",
    "save_document",
    "close_tab",
    "close_diffs",
    "search_replace_global",
    "edit_file",
  }

  for _, tool_name in ipairs(builtin_tools) do
    local ok, tool_module = pcall(require, "prism.mcp.tools." .. tool_name)
    if ok and tool_module.register then
      tool_module.register(M)
    else
      util.log.warn("Failed to load builtin tool: " .. tool_name)
    end
  end
end

return M
