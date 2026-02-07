--- prism.nvim memory store module
--- File-based storage for memory entries
--- @module prism.memory.store

local M = {}

--- Default memory file path
local DEFAULT_PATH = ".prism/memory.json"

--- Ensure directory exists
--- @param path string File path
local function ensure_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Load memory data from file
--- @param path string|nil Path to memory file
--- @return table|nil Data or nil on error
function M.load(path)
  path = path or DEFAULT_PATH

  -- Make path relative to cwd if not absolute
  if not vim.startswith(path, "/") then
    path = vim.fn.getcwd() .. "/" .. path
  end

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

--- Save memory data to file
--- @param path string|nil Path to memory file
--- @param data table Data to save
--- @return boolean success
function M.save(path, data)
  path = path or DEFAULT_PATH

  -- Make path relative to cwd if not absolute
  if not vim.startswith(path, "/") then
    path = vim.fn.getcwd() .. "/" .. path
  end

  ensure_dir(path)

  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    return false
  end

  local write_ok = pcall(vim.fn.writefile, { json_str }, path)
  return write_ok
end

--- Append a single entry to memory file
--- @param path string|nil Path to memory file
--- @param entry table Entry to append
--- @return boolean success
function M.append(path, entry)
  local data = M.load(path) or { entries = {} }

  if not data.entries then
    data.entries = {}
  end

  table.insert(data.entries, entry)
  return M.save(path, data)
end

--- List all memory files in a directory
--- @param dir string|nil Directory path (default: .prism/)
--- @return string[] List of memory file paths
function M.list(dir)
  dir = dir or ".prism"

  -- Make path relative to cwd if not absolute
  if not vim.startswith(dir, "/") then
    dir = vim.fn.getcwd() .. "/" .. dir
  end

  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  local files = vim.fn.glob(dir .. "/*.json", false, true)
  return files
end

--- Delete a memory file
--- @param path string Path to file
--- @return boolean success
function M.delete(path)
  -- Make path relative to cwd if not absolute
  if not vim.startswith(path, "/") then
    path = vim.fn.getcwd() .. "/" .. path
  end

  if vim.fn.filereadable(path) == 1 then
    return vim.fn.delete(path) == 0
  end
  return false
end

--- Check if memory file exists
--- @param path string|nil Path to check
--- @return boolean exists
function M.exists(path)
  path = path or DEFAULT_PATH

  if not vim.startswith(path, "/") then
    path = vim.fn.getcwd() .. "/" .. path
  end

  return vim.fn.filereadable(path) == 1
end

return M
