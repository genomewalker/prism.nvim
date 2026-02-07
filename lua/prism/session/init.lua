--- prism.nvim session module
--- Session management with auto-save and restore
--- @module prism.session

local M = {}

local store = require("prism.session.store")
local event = require("prism.event")
local cost = require("prism.cost")
local memory = require("prism.memory")

--- Current session state
--- @type table
local current = {
  name = nil,
  started_at = nil,
  event_log = {},
  hunks = {},
  terminal_output = {},
  git_state = nil,
  checkpoints = {},
}

--- Generate session name
--- @return string Session name with timestamp
local function generate_name()
  return os.date("%Y%m%d_%H%M%S")
end

--- Capture current git state
--- @return table|nil Git state
local function capture_git_state()
  local handle = io.popen("git rev-parse HEAD 2>/dev/null")
  if not handle then
    return nil
  end

  local commit = handle:read("*l")
  handle:close()

  if not commit then
    return nil
  end

  -- Get branch
  handle = io.popen("git rev-parse --abbrev-ref HEAD 2>/dev/null")
  local branch = handle and handle:read("*l") or nil
  if handle then
    handle:close()
  end

  -- Get status (dirty or clean)
  handle = io.popen("git status --porcelain 2>/dev/null")
  local status_output = handle and handle:read("*a") or ""
  if handle then
    handle:close()
  end

  return {
    commit = commit,
    branch = branch,
    dirty = #status_output > 0,
    captured_at = os.time(),
  }
end

--- Start a new session
--- @param name string|nil Optional session name
--- @return string Session name
function M.start(name)
  name = name or generate_name()

  current = {
    name = name,
    started_at = os.time(),
    event_log = {},
    hunks = {},
    terminal_output = {},
    git_state = capture_git_state(),
    checkpoints = {},
  }

  -- Subscribe to events for logging
  event.on("*", function(payload, evt_name)
    table.insert(current.event_log, {
      event = evt_name,
      payload = payload,
      timestamp = vim.loop.hrtime() / 1e6,
    })
  end)

  event.emit(event.events.SESSION_STARTED, { name = name })
  return name
end

--- Save current session
--- @param name string|nil Session name (uses current if nil)
--- @return boolean success
function M.save(name)
  name = name or current.name
  if not name then
    name = generate_name()
    current.name = name
  end

  local data = {
    name = name,
    started_at = current.started_at,
    saved_at = os.time(),
    event_log = current.event_log,
    hunks = current.hunks,
    terminal_output = current.terminal_output,
    git_state = current.git_state,
    checkpoints = current.checkpoints,
    cost = cost.export(),
    memory = memory.export(),
  }

  local path = store.name_to_path(name)
  return store.save(path, data)
end

--- Restore a session
--- @param name string Session name
--- @return boolean success
function M.restore(name)
  local path = store.name_to_path(name)
  local data = store.load(path)

  if not data then
    return false
  end

  current = {
    name = data.name,
    started_at = data.started_at,
    event_log = data.event_log or {},
    hunks = data.hunks or {},
    terminal_output = data.terminal_output or {},
    git_state = data.git_state,
    checkpoints = data.checkpoints or {},
  }

  -- Restore cost tracking state
  if data.cost then
    cost.import(data.cost)
  end

  -- Restore memory state
  if data.memory then
    memory.import(data.memory)
  end

  event.emit(event.events.SESSION_RESUMED, { name = name, data = data })
  return true
end

--- List available sessions
--- @return table[] Sessions {name, path, mtime}
function M.list()
  return store.list()
end

--- Delete a session
--- @param name string Session name
--- @return boolean success
function M.delete(name)
  local path = store.name_to_path(name)
  return store.delete(path)
end

--- Create a checkpoint
--- @param label string|nil Optional checkpoint label
--- @return table Checkpoint data
function M.checkpoint(label)
  local checkpoint = {
    label = label,
    timestamp = os.time(),
    event_count = #current.event_log,
    hunk_count = #current.hunks,
    git_state = capture_git_state(),
    cost = cost.get_session_cost(),
  }

  table.insert(current.checkpoints, checkpoint)

  -- Auto-save on checkpoint
  M.save()

  return checkpoint
end

--- Get current session info
--- @return table|nil Current session or nil
function M.get_current()
  if not current.name then
    return nil
  end

  return {
    name = current.name,
    started_at = current.started_at,
    event_count = #current.event_log,
    hunk_count = #current.hunks,
    checkpoint_count = #current.checkpoints,
    git_state = current.git_state,
  }
end

--- Add a hunk to current session
--- @param hunk table Diff hunk data
function M.add_hunk(hunk)
  table.insert(current.hunks, {
    hunk = hunk,
    timestamp = os.time(),
  })
end

--- Add terminal output to session
--- @param output string Terminal output
function M.add_terminal_output(output)
  table.insert(current.terminal_output, {
    output = output,
    timestamp = os.time(),
  })
end

--- Get session hunks
--- @return table[] Hunks
function M.get_hunks()
  return vim.deepcopy(current.hunks)
end

--- Get terminal output
--- @return table[] Terminal output entries
function M.get_terminal_output()
  return vim.deepcopy(current.terminal_output)
end

--- End current session
--- @param save boolean|nil Whether to save before ending (default true)
function M.end_session(save_session)
  if save_session ~= false and current.name then
    M.save()
  end

  event.emit(event.events.SESSION_ENDED, { name = current.name })

  current = {
    name = nil,
    started_at = nil,
    event_log = {},
    hunks = {},
    terminal_output = {},
    git_state = nil,
    checkpoints = {},
  }
end

--- Export session for external use
--- @return table Full session data
function M.export()
  return {
    name = current.name,
    started_at = current.started_at,
    event_log = vim.deepcopy(current.event_log),
    hunks = vim.deepcopy(current.hunks),
    terminal_output = vim.deepcopy(current.terminal_output),
    git_state = current.git_state,
    checkpoints = vim.deepcopy(current.checkpoints),
    cost = cost.export(),
    memory = memory.export(),
  }
end

--- Submodule access
M.store = store

return M
