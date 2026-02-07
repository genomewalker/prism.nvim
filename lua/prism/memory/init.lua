--- prism.nvim memory module
--- Persistent memory with text search
--- @module prism.memory

local M = {}

local store = require("prism.memory.store")
local search = require("prism.memory.search")

--- Memory state
--- @type table
local state = {
  entries = {},
  index = nil,
  dirty = false,
  path = nil,
}

--- Initialize/load memory from path
--- @param path string|nil Memory file path
function M.setup(path)
  state.path = path
  local data = store.load(path)
  if data and data.entries then
    state.entries = data.entries
    M.rebuild_index()
  end
end

--- Rebuild the search index
function M.rebuild_index()
  state.index = search.index(state.entries)
end

--- Save a memory entry
--- @param key string Unique key/identifier
--- @param content string Content to remember
--- @param metadata table|nil Optional metadata {tags, source, etc}
--- @return table Entry that was saved
function M.save(key, content, metadata)
  metadata = metadata or {}

  -- Check if key exists
  local existing_idx = nil
  for i, entry in ipairs(state.entries) do
    if entry.key == key then
      existing_idx = i
      break
    end
  end

  local entry = {
    key = key,
    content = content,
    metadata = metadata,
    created_at = existing_idx and state.entries[existing_idx].created_at or os.time(),
    updated_at = os.time(),
  }

  if existing_idx then
    state.entries[existing_idx] = entry
  else
    table.insert(state.entries, entry)
  end

  state.dirty = true
  M.rebuild_index()

  return entry
end

--- Query memory using text search
--- @param query_text string Search query
--- @param limit number|nil Max results (default 10)
--- @return table[] Matching entries with scores
function M.query(query_text, limit)
  if not state.index then
    M.rebuild_index()
  end

  return search.search(query_text, state.index, limit or 10)
end

--- Get entry by key
--- @param key string Entry key
--- @return table|nil Entry or nil
function M.get(key)
  for _, entry in ipairs(state.entries) do
    if entry.key == key then
      return vim.deepcopy(entry)
    end
  end
  return nil
end

--- List all entries
--- @param filter table|nil Optional filter {tags, since, limit}
--- @return table[] Entries
function M.list(filter)
  filter = filter or {}
  local results = {}

  for _, entry in ipairs(state.entries) do
    local match = true

    -- Filter by tags
    if filter.tags and entry.metadata and entry.metadata.tags then
      local has_tag = false
      for _, ftag in ipairs(filter.tags) do
        for _, etag in ipairs(entry.metadata.tags) do
          if ftag == etag then
            has_tag = true
            break
          end
        end
        if has_tag then
          break
        end
      end
      match = match and has_tag
    end

    -- Filter by time
    if filter.since and entry.created_at < filter.since then
      match = false
    end

    if match then
      table.insert(results, vim.deepcopy(entry))
    end

    if filter.limit and #results >= filter.limit then
      break
    end
  end

  return results
end

--- Delete an entry by key
--- @param key string Entry key
--- @return boolean success
function M.delete(key)
  for i, entry in ipairs(state.entries) do
    if entry.key == key then
      table.remove(state.entries, i)
      state.dirty = true
      M.rebuild_index()
      return true
    end
  end
  return false
end

--- Clear all memory entries
function M.clear()
  state.entries = {}
  state.index = nil
  state.dirty = true
end

--- Persist memory to disk
--- @return boolean success
function M.persist()
  if not state.dirty and store.exists(state.path) then
    return true
  end

  local success = store.save(state.path, { entries = state.entries })
  if success then
    state.dirty = false
  end
  return success
end

--- Get memory stats
--- @return table Stats
function M.stats()
  return {
    count = #state.entries,
    dirty = state.dirty,
    path = state.path,
  }
end

--- Export state for session persistence
--- @return table Exportable state
function M.export()
  return vim.deepcopy(state.entries)
end

--- Import entries from session
--- @param entries table[] Entries to import
function M.import(entries)
  if not entries then
    return
  end
  state.entries = vim.deepcopy(entries)
  state.dirty = true
  M.rebuild_index()
end

--- Submodule access
M.search = search
M.store = store

return M
