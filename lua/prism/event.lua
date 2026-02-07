--- prism.nvim event bus module
--- Pub/sub event system with CQRS-lite event log for session replay
--- @module prism.event

local M = {}

--- Event subscribers
--- @type table<string, function[]>
local subscribers = {}

--- One-time subscribers (removed after first call)
--- @type table<string, function[]>
local once_subscribers = {}

--- Event history log for session replay
--- @type table[]
local event_log = {}

--- Maximum event log size (prevents memory issues)
local MAX_LOG_SIZE = 1000

--- Generate timestamp
--- @return number timestamp in milliseconds
local function timestamp()
  return vim.loop.hrtime() / 1e6
end

--- Add event to history log
--- @param event string Event name
--- @param payload any Event payload
local function log_event(event, payload)
  local entry = {
    id = #event_log + 1,
    event = event,
    payload = payload,
    timestamp = timestamp(),
  }

  table.insert(event_log, entry)

  -- Trim log if too large (keep most recent)
  if #event_log > MAX_LOG_SIZE then
    local overflow = #event_log - MAX_LOG_SIZE
    for _ = 1, overflow do
      table.remove(event_log, 1)
    end
    -- Renumber IDs
    for i, e in ipairs(event_log) do
      e.id = i
    end
  end
end

--- Emit an event to all subscribers
--- @param event string Event name
--- @param payload any Event payload (optional)
function M.emit(event, payload)
  -- Log the event
  log_event(event, payload)

  -- Call regular subscribers
  if subscribers[event] then
    for _, callback in ipairs(subscribers[event]) do
      local ok, err = pcall(callback, payload, event)
      if not ok then
        vim.schedule(function()
          vim.notify(
            string.format("[prism.nvim] Event handler error for '%s': %s", event, err),
            vim.log.levels.ERROR
          )
        end)
      end
    end
  end

  -- Call and remove one-time subscribers
  if once_subscribers[event] then
    local callbacks = once_subscribers[event]
    once_subscribers[event] = nil
    for _, callback in ipairs(callbacks) do
      local ok, err = pcall(callback, payload, event)
      if not ok then
        vim.schedule(function()
          vim.notify(
            string.format("[prism.nvim] One-time event handler error for '%s': %s", event, err),
            vim.log.levels.ERROR
          )
        end)
      end
    end
  end

  -- Emit wildcard event for debugging/logging
  if event ~= "*" and subscribers["*"] then
    for _, callback in ipairs(subscribers["*"]) do
      local ok, _ = pcall(callback, payload, event)
      if not ok then
        -- Silently ignore wildcard handler errors
      end
    end
  end
end

--- Subscribe to an event
--- @param event string Event name (use "*" for all events)
--- @param callback function Callback function(payload, event_name)
--- @return function Unsubscribe function
function M.on(event, callback)
  if type(callback) ~= "function" then
    error("callback must be a function")
  end

  if not subscribers[event] then
    subscribers[event] = {}
  end

  table.insert(subscribers[event], callback)

  -- Return unsubscribe function
  return function()
    M.off(event, callback)
  end
end

--- Unsubscribe from an event
--- @param event string Event name
--- @param callback function The callback to remove
--- @return boolean success Whether the callback was found and removed
function M.off(event, callback)
  if not subscribers[event] then
    return false
  end

  for i, cb in ipairs(subscribers[event]) do
    if cb == callback then
      table.remove(subscribers[event], i)
      return true
    end
  end

  -- Also check once subscribers
  if once_subscribers[event] then
    for i, cb in ipairs(once_subscribers[event]) do
      if cb == callback then
        table.remove(once_subscribers[event], i)
        return true
      end
    end
  end

  return false
end

--- Subscribe to an event once (auto-unsubscribe after first call)
--- @param event string Event name
--- @param callback function Callback function(payload, event_name)
--- @return function Unsubscribe function
function M.once(event, callback)
  if type(callback) ~= "function" then
    error("callback must be a function")
  end

  if not once_subscribers[event] then
    once_subscribers[event] = {}
  end

  table.insert(once_subscribers[event], callback)

  -- Return unsubscribe function
  return function()
    M.off(event, callback)
  end
end

--- Get event history log
--- @param filter table|nil Optional filter { event = "event_name", since = timestamp, limit = number }
--- @return table[] Event log entries
function M.history(filter)
  if not filter then
    return vim.deepcopy(event_log)
  end

  local result = {}
  local count = 0
  local limit = filter.limit or #event_log

  for i = #event_log, 1, -1 do
    local entry = event_log[i]
    local match = true

    if filter.event and entry.event ~= filter.event then
      match = false
    end

    if filter.since and entry.timestamp < filter.since then
      match = false
    end

    if match then
      table.insert(result, 1, vim.deepcopy(entry))
      count = count + 1
      if count >= limit then
        break
      end
    end
  end

  return result
end

--- Clear all subscribers and event log
--- @param options table|nil { subscribers = bool, log = bool } defaults to both true
function M.clear(options)
  options = options or { subscribers = true, log = true }

  if options.subscribers ~= false then
    subscribers = {}
    once_subscribers = {}
  end

  if options.log ~= false then
    event_log = {}
  end
end

--- Get subscriber count for an event
--- @param event string|nil Event name (nil for total count)
--- @return number count
function M.subscriber_count(event)
  if event then
    local regular = subscribers[event] and #subscribers[event] or 0
    local once = once_subscribers[event] and #once_subscribers[event] or 0
    return regular + once
  end

  local total = 0
  for _, cbs in pairs(subscribers) do
    total = total + #cbs
  end
  for _, cbs in pairs(once_subscribers) do
    total = total + #cbs
  end
  return total
end

--- Replay events from history
--- Useful for rebuilding state or debugging
--- @param entries table[] Event log entries to replay
--- @param options table|nil { delay_ms = number } Optional delay between events
function M.replay(entries, options)
  options = options or {}
  local delay = options.delay_ms or 0

  if delay > 0 then
    local i = 1
    local function replay_next()
      if i <= #entries then
        local entry = entries[i]
        M.emit(entry.event, entry.payload)
        i = i + 1
        vim.defer_fn(replay_next, delay)
      end
    end
    replay_next()
  else
    for _, entry in ipairs(entries) do
      M.emit(entry.event, entry.payload)
    end
  end
end

--- Common event names (for documentation/autocomplete)
M.events = {
  -- Terminal events
  TERMINAL_OPENED = "terminal:opened",
  TERMINAL_CLOSED = "terminal:closed",
  TERMINAL_OUTPUT = "terminal:output",

  -- Message events
  MESSAGE_SENT = "message:sent",
  MESSAGE_RECEIVED = "message:received",
  MESSAGE_ERROR = "message:error",

  -- Diff events
  DIFF_CREATED = "diff:created",
  DIFF_ACCEPTED = "diff:accepted",
  DIFF_REJECTED = "diff:rejected",

  -- Selection events
  SELECTION_CHANGED = "selection:changed",
  CONTEXT_UPDATED = "context:updated",

  -- Session events
  SESSION_STARTED = "session:started",
  SESSION_ENDED = "session:ended",
  SESSION_RESUMED = "session:resumed",

  -- MCP events
  MCP_CONNECTED = "mcp:connected",
  MCP_DISCONNECTED = "mcp:disconnected",
  MCP_ERROR = "mcp:error",

  -- Cost tracking
  COST_UPDATED = "cost:updated",

  -- Model events
  MODEL_CHANGED = "model:changed",

  -- Plugin lifecycle
  PLUGIN_LOADED = "plugin:loaded",
  PLUGIN_UNLOADED = "plugin:unloaded",
}

return M
