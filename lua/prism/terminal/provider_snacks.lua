--- prism.nvim snacks.nvim terminal provider
--- Uses snacks.nvim terminal for floating terminal management
--- @module prism.terminal.provider_snacks

local M = {}

--- Terminal state
--- @type table|nil
local terminal = nil

--- Check if snacks.nvim terminal is available
--- @return boolean
function M.is_available()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return false
  end
  return snacks.terminal ~= nil
end

--- Open terminal with command
--- @param cmd string|string[] Command to run
--- @param env table|nil Environment variables
--- @param opts table|nil Options { cwd, on_exit, on_open }
--- @return boolean success
function M.open(cmd, env, opts)
  if not M.is_available() then
    vim.notify("[prism.nvim] snacks.nvim terminal not available", vim.log.levels.ERROR)
    return false
  end

  opts = opts or {}
  local snacks = require("snacks")

  -- Build terminal options
  local term_opts = {
    cmd = cmd,
    cwd = opts.cwd,
    env = env,
    interactive = true,
    win = {
      position = opts.position or "right",
      width = opts.width or 0.4,
      height = opts.height or 0.8,
      border = opts.border or "rounded",
      title = opts.title or " Claude Code ",
      title_pos = "center",
    },
  }

  -- Create terminal
  terminal = snacks.terminal.open(term_opts)

  if terminal and opts.on_open then
    vim.schedule(function()
      opts.on_open(terminal)
    end)
  end

  return terminal ~= nil
end

--- Close terminal
--- @return boolean success
function M.close()
  if not terminal then
    return false
  end

  local ok = pcall(function()
    if terminal.close then
      terminal:close()
    elseif terminal.hide then
      terminal:hide()
    end
  end)

  if ok then
    terminal = nil
  end

  return ok
end

--- Toggle terminal visibility
--- @return boolean visible New visibility state
function M.toggle()
  if not terminal then
    return false
  end

  local ok, result = pcall(function()
    if terminal.toggle then
      terminal:toggle()
      return terminal:is_visible() or false
    end
    return false
  end)

  return ok and result or false
end

--- Get terminal buffer number
--- @return number|nil bufnr
function M.get_bufnr()
  if not terminal then
    return nil
  end

  local ok, bufnr = pcall(function()
    if terminal.buf then
      return terminal.buf
    end
    return nil
  end)

  return ok and bufnr or nil
end

--- Check if terminal is visible
--- @return boolean
function M.is_visible()
  if not terminal then
    return false
  end

  local ok, visible = pcall(function()
    if terminal.is_visible then
      return terminal:is_visible()
    end
    return false
  end)

  return ok and visible or false
end

--- Send text to terminal
--- @param text string Text to send
--- @return boolean success
function M.send(text)
  if not terminal then
    return false
  end

  local ok = pcall(function()
    if terminal.send then
      terminal:send(text)
    end
  end)

  return ok
end

--- Get terminal instance for advanced operations
--- @return table|nil terminal
function M.get_terminal()
  return terminal
end

return M
