--- prism.nvim git index watcher
--- Watch .git/index for changes using vim.uv
--- @module prism.git.watcher

local M = {}

--- Active watchers
--- @type table<string, uv_fs_event_t>
local watchers = {}

--- Callbacks for each watched root
--- @type table<string, function[]>
local callbacks = {}

--- Debounce timers
--- @type table<string, uv_timer_t>
local debounce_timers = {}

--- Debounce delay in milliseconds
local DEBOUNCE_MS = 100

--- Get .git directory for a root
--- @param root string Git root directory
--- @return string|nil git_dir
local function get_git_dir(root)
  local git_dir = root .. "/.git"
  local stat = vim.loop.fs_stat(git_dir)

  if not stat then
    return nil
  end

  -- Handle worktrees where .git is a file pointing to the actual git dir
  if stat.type == "file" then
    local content = vim.fn.readfile(git_dir)
    if content[1] then
      local gitdir_path = content[1]:match("gitdir: (.+)")
      if gitdir_path then
        -- Resolve relative paths
        if not gitdir_path:match("^/") then
          gitdir_path = root .. "/" .. gitdir_path
        end
        return gitdir_path
      end
    end
    return nil
  end

  return git_dir
end

--- Trigger callbacks for a root
--- @param root string Git root directory
local function trigger_callbacks(root)
  if not callbacks[root] then
    return
  end

  for _, callback in ipairs(callbacks[root]) do
    local ok, err = pcall(callback, root)
    if not ok then
      vim.schedule(function()
        vim.notify("[prism.nvim] Git watcher callback error: " .. tostring(err), vim.log.levels.WARN)
      end)
    end
  end
end

--- Handle file change event with debouncing
--- @param root string Git root directory
local function on_change(root)
  -- Cancel existing debounce timer
  if debounce_timers[root] then
    debounce_timers[root]:stop()
  end

  -- Create debounce timer
  debounce_timers[root] = vim.loop.new_timer()
  debounce_timers[root]:start(DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      trigger_callbacks(root)
    end)
    if debounce_timers[root] then
      debounce_timers[root]:stop()
      debounce_timers[root]:close()
      debounce_timers[root] = nil
    end
  end)
end

--- Start watching git index for a repository
--- @param root string Git root directory
--- @param callback function Callback function(root)
--- @return boolean success
function M.start(root, callback)
  if type(callback) ~= "function" then
    error("callback must be a function")
  end

  -- Initialize callbacks for this root
  if not callbacks[root] then
    callbacks[root] = {}
  end
  table.insert(callbacks[root], callback)

  -- Already watching this root
  if watchers[root] then
    return true
  end

  local git_dir = get_git_dir(root)
  if not git_dir then
    return false
  end

  local index_path = git_dir .. "/index"

  -- Check if index exists
  if not vim.loop.fs_stat(index_path) then
    -- Watch the git dir instead (index may not exist yet)
    index_path = git_dir
  end

  -- Create file watcher
  local watcher = vim.loop.new_fs_event()
  if not watcher then
    return false
  end

  local ok, err = watcher:start(index_path, {}, function(err_inner, filename, events)
    if err_inner then
      vim.schedule(function()
        vim.notify("[prism.nvim] Git watcher error: " .. tostring(err_inner), vim.log.levels.WARN)
      end)
      return
    end

    -- Trigger on any change
    if events and (events.change or events.rename) then
      on_change(root)
    end
  end)

  if not ok then
    watcher:close()
    vim.schedule(function()
      vim.notify("[prism.nvim] Failed to start git watcher: " .. tostring(err), vim.log.levels.WARN)
    end)
    return false
  end

  watchers[root] = watcher
  return true
end

--- Stop watching git index for a repository
--- @param root string Git root directory
--- @return boolean success
function M.stop(root)
  -- Clean up watcher
  if watchers[root] then
    watchers[root]:stop()
    watchers[root]:close()
    watchers[root] = nil
  end

  -- Clean up debounce timer
  if debounce_timers[root] then
    debounce_timers[root]:stop()
    debounce_timers[root]:close()
    debounce_timers[root] = nil
  end

  -- Clear callbacks
  callbacks[root] = nil

  return true
end

--- Stop all watchers
function M.stop_all()
  for root, _ in pairs(watchers) do
    M.stop(root)
  end
end

--- Check if watching a repository
--- @param root string Git root directory
--- @return boolean watching
function M.is_watching(root)
  return watchers[root] ~= nil
end

--- Get list of watched repositories
--- @return string[] roots
function M.get_watched()
  local roots = {}
  for root, _ in pairs(watchers) do
    table.insert(roots, root)
  end
  return roots
end

--- Remove a specific callback
--- @param root string Git root directory
--- @param callback function The callback to remove
--- @return boolean success
function M.remove_callback(root, callback)
  if not callbacks[root] then
    return false
  end

  for i, cb in ipairs(callbacks[root]) do
    if cb == callback then
      table.remove(callbacks[root], i)

      -- Stop watcher if no callbacks remain
      if #callbacks[root] == 0 then
        M.stop(root)
      end

      return true
    end
  end

  return false
end

--- Manually trigger callbacks (for testing/forcing refresh)
--- @param root string|nil Git root (nil for all)
function M.trigger(root)
  if root then
    trigger_callbacks(root)
  else
    for r, _ in pairs(callbacks) do
      trigger_callbacks(r)
    end
  end
end

return M
