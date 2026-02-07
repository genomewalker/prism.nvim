--- prism.nvim session store module
--- File-based storage for session data
--- @module prism.session.store

local M = {}

--- Default session directory
local DEFAULT_DIR = ".prism/sessions"

--- Ensure directory exists
--- @param path string File path
local function ensure_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Get absolute path
--- @param path string Path (may be relative)
--- @return string Absolute path
local function abs_path(path)
  if not vim.startswith(path, "/") then
    return vim.fn.getcwd() .. "/" .. path
  end
  return path
end

--- Load session data from file
--- @param path string Path to session file
--- @return table|nil Data or nil on error
function M.load(path)
  path = abs_path(path)

  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or #content == 0 then
    return nil
  end

  local json_str = table.concat(content, "\n")
  local decode_ok, data = pcall(vim.json.decode, json_str)
  if not decode_ok then
    return nil
  end

  return data
end

--- Save session data to file
--- @param path string Path to session file
--- @param data table Data to save
--- @return boolean success
function M.save(path, data)
  path = abs_path(path)
  ensure_dir(path)

  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    return false
  end

  local write_ok = pcall(vim.fn.writefile, { json_str }, path)
  return write_ok
end

--- List all session files in directory
--- @param dir string|nil Directory path (default: .prism/sessions/)
--- @return table[] List of session info {name, path, mtime}
function M.list(dir)
  dir = dir or DEFAULT_DIR
  dir = abs_path(dir)

  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  local files = vim.fn.glob(dir .. "/*.json", false, true)
  local sessions = {}

  for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ":t:r")
    local mtime = vim.fn.getftime(file)
    table.insert(sessions, {
      name = name,
      path = file,
      mtime = mtime,
    })
  end

  -- Sort by mtime descending (most recent first)
  table.sort(sessions, function(a, b)
    return a.mtime > b.mtime
  end)

  return sessions
end

--- Delete a session file
--- @param path string Path to file
--- @return boolean success
function M.delete(path)
  path = abs_path(path)

  if vim.fn.filereadable(path) == 1 then
    return vim.fn.delete(path) == 0
  end
  return false
end

--- Check if session file exists
--- @param path string Path to check
--- @return boolean exists
function M.exists(path)
  path = abs_path(path)
  return vim.fn.filereadable(path) == 1
end

--- Generate session path from name
--- @param name string Session name
--- @param dir string|nil Directory (default: .prism/sessions/)
--- @return string Full path
function M.name_to_path(name, dir)
  dir = dir or DEFAULT_DIR
  return dir .. "/" .. name .. ".json"
end

--- Get default directory
--- @return string Default session directory
function M.default_dir()
  return DEFAULT_DIR
end

return M
