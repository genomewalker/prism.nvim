--- prism.nvim MCP Lock File Management
--- Manages ~/.claude/ide/[port].lock files for Claude CLI discovery
--- @module prism.mcp.lockfile

local util = require("prism.util")

local M = {}

--- Current lock file path
--- @type string|nil
local current_lock_path = nil

--- Get Claude config directory
--- Uses $CLAUDE_CONFIG_DIR if set, otherwise ~/.claude
--- @return string Config directory path
function M.get_config_dir()
  local config_dir = os.getenv("CLAUDE_CONFIG_DIR")
  if config_dir and config_dir ~= "" then
    return config_dir
  end
  return vim.fn.expand("~/.claude")
end

--- Get the lock directory path
--- @return string Lock directory path
function M.get_lock_dir()
  return M.get_config_dir() .. "/ide"
end

--- Get lock file path for a port
--- @param port number Port number
--- @return string Lock file path
function M.get_lock_path(port)
  return M.get_lock_dir() .. "/" .. port .. ".lock"
end

--- Create lock file content
--- @param port number Server port
--- @param auth_token string Authentication token
--- @return table Lock file content
function M.create_content(port, auth_token)
  local version_ok, prism = pcall(require, "prism")
  local client_version = version_ok and prism.version_string and prism.version_string() or "0.1.0"

  return {
    pid = vim.fn.getpid(),
    workspaceFolders = { vim.fn.getcwd() },
    ideName = "neovim",
    ideVersion = tostring(vim.version()),
    transport = "ws",
    host = "127.0.0.1",
    port = port,
    authToken = auth_token,
    clientName = "prism.nvim",
    clientVersion = client_version,
    timestamp = os.time(),
  }
end

--- Create lock file atomically
--- @param port number Server port
--- @param auth_token string Authentication token
--- @return boolean success
--- @return string|nil error
function M.create(port, auth_token)
  if not port then
    return false, "Port is required"
  end
  if not auth_token then
    return false, "Auth token is required"
  end

  local lock_dir = M.get_lock_dir()
  local lock_path = M.get_lock_path(port)

  -- Create directory if needed
  if vim.fn.isdirectory(lock_dir) == 0 then
    local ok = vim.fn.mkdir(lock_dir, "p")
    if ok == 0 then
      return false, "Failed to create lock directory: " .. lock_dir
    end
  end

  -- Create content
  local content = M.create_content(port, auth_token)
  local json, err = util.json_encode(content)
  if not json then
    return false, "Failed to encode lock file: " .. (err or "unknown error")
  end

  -- Atomic write: write to temp file, then rename
  local temp_path = lock_path .. ".tmp." .. vim.fn.getpid()
  local file, open_err = io.open(temp_path, "w")
  if not file then
    return false, "Failed to open temp file: " .. (open_err or "unknown error")
  end

  file:write(json)
  file:close()

  -- Rename (atomic on POSIX)
  local rename_ok = vim.loop.fs_rename(temp_path, lock_path)
  if not rename_ok then
    vim.fn.delete(temp_path)
    return false, "Failed to rename temp file to lock file"
  end

  current_lock_path = lock_path
  util.log.debug("Created lock file: " .. lock_path)

  return true, nil
end

--- Write lock file (alias for create)
--- @param port number Server port
--- @param auth_token string Authentication token
--- @return boolean success
--- @return string|nil error
function M.write(port, auth_token)
  return M.create(port, auth_token)
end

--- Remove lock file
--- @param port number|nil Port number (uses current if nil)
--- @return boolean success
function M.remove(port)
  local lock_path

  if port then
    lock_path = M.get_lock_path(port)
  elseif current_lock_path then
    lock_path = current_lock_path
  else
    return false
  end

  if vim.fn.filereadable(lock_path) == 1 then
    local ok = vim.fn.delete(lock_path)
    if ok == 0 then
      util.log.debug("Removed lock file: " .. lock_path)
      if lock_path == current_lock_path then
        current_lock_path = nil
      end
      return true
    end
  end

  return false
end

--- Read lock file
--- @param port number Port number
--- @return table|nil content
--- @return string|nil error
function M.read(port)
  local lock_path = M.get_lock_path(port)

  if vim.fn.filereadable(lock_path) ~= 1 then
    return nil, "Lock file not found"
  end

  local file, open_err = io.open(lock_path, "r")
  if not file then
    return nil, "Failed to open lock file: " .. (open_err or "unknown error")
  end

  local content = file:read("*a")
  file:close()

  local data, decode_err = util.json_decode(content)
  if not data then
    return nil, "Failed to decode lock file: " .. (decode_err or "unknown error")
  end

  return data, nil
end

--- Check if a lock file exists and is valid (process still running)
--- @param port number Port number
--- @return boolean valid
function M.is_valid(port)
  local data, _ = M.read(port)
  if not data then
    return false
  end

  -- Check if the PID is still running
  local pid = data.pid
  if not pid then
    return false
  end

  -- On Unix, check if process exists
  local check = vim.fn.system("kill -0 " .. pid .. " 2>/dev/null; echo $?")
  return vim.trim(check) == "0"
end

--- Check if lock file is stale (PID no longer running)
--- @param port number Port number
--- @return boolean is_stale
function M.is_stale(port)
  return not M.is_valid(port)
end

--- Find all lock files
--- @return table[] Lock file data with port numbers
function M.find_all()
  local lock_dir = M.get_lock_dir()
  local locks = {}

  if vim.fn.isdirectory(lock_dir) == 0 then
    return locks
  end

  local files = vim.fn.glob(lock_dir .. "/*.lock", false, true)
  for _, file in ipairs(files) do
    local port_str = vim.fn.fnamemodify(file, ":t:r")
    local port = tonumber(port_str)
    if port then
      local data = M.read(port)
      if data then
        data._port = port
        data._path = file
        data._valid = M.is_valid(port)
        table.insert(locks, data)
      end
    end
  end

  return locks
end

--- Clean up stale lock files
--- @return number count Number of files cleaned
function M.cleanup()
  local locks = M.find_all()
  local count = 0

  for _, lock in ipairs(locks) do
    if not lock._valid then
      if vim.fn.delete(lock._path) == 0 then
        count = count + 1
        util.log.debug("Cleaned up stale lock file: " .. lock._path)
      end
    end
  end

  return count
end

--- Get current lock file path
--- @return string|nil
function M.get_current()
  return current_lock_path
end

return M
