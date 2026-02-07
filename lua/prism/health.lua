--- prism.nvim health check module
--- Provides :checkhealth prism diagnostics
--- @module prism.health

local M = {}

local health = vim.health

--- Check if a command exists
--- @param cmd string Command name
--- @return boolean exists
local function command_exists(cmd)
  return vim.fn.executable(cmd) == 1
end

--- Check if a Lua module can be loaded
--- @param module_name string Module name
--- @return boolean exists
local function module_exists(module_name)
  local ok = pcall(require, module_name)
  return ok
end

--- Get Claude CLI version
--- @return string|nil version
local function get_claude_version()
  local handle = io.popen("claude --version 2>/dev/null")
  if not handle then
    return nil
  end

  local output = handle:read("*a")
  handle:close()

  if output and output ~= "" then
    return vim.trim(output)
  end
  return nil
end

--- Get git version
--- @return string|nil version
local function get_git_version()
  local handle = io.popen("git --version 2>/dev/null")
  if not handle then
    return nil
  end

  local output = handle:read("*a")
  handle:close()

  if output and output ~= "" then
    return vim.trim(output)
  end
  return nil
end

--- Check if a port is available
--- @param port number Port number
--- @return boolean available
local function port_available(port)
  local uv = vim.loop

  local server = uv.new_tcp()
  if not server then
    return false
  end

  local ok = pcall(function()
    server:bind("127.0.0.1", port)
  end)

  server:close()
  return ok
end

--- Find available port in range
--- @param min_port number Minimum port
--- @param max_port number Maximum port
--- @return number|nil port
local function find_available_port(min_port, max_port)
  for port = min_port, max_port do
    if port_available(port) then
      return port
    end
  end
  return nil
end

--- Run health checks
function M.check()
  health.start("prism.nvim")

  -- Check Neovim version
  local nvim_version = vim.version()
  if nvim_version.major > 0 or (nvim_version.major == 0 and nvim_version.minor >= 9) then
    health.ok(string.format("Neovim version: %d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch))
  else
    health.error(
      string.format("Neovim version %d.%d.%d is too old", nvim_version.major, nvim_version.minor, nvim_version.patch),
      "prism.nvim requires Neovim 0.9.0 or later"
    )
  end

  -- Check Claude CLI
  health.start("Claude CLI")
  if command_exists("claude") then
    local version = get_claude_version()
    if version then
      health.ok("Claude CLI installed: " .. version)
    else
      health.ok("Claude CLI installed (version unknown)")
    end
  else
    health.error(
      "Claude CLI not found",
      {
        "Install Claude CLI: npm install -g @anthropic-ai/claude-code",
        "Or visit: https://github.com/anthropics/claude-code",
      }
    )
  end

  -- Check required dependencies
  health.start("Dependencies")

  -- plenary.nvim
  if module_exists("plenary") then
    health.ok("plenary.nvim installed")
  else
    health.error(
      "plenary.nvim not found",
      "Install plenary.nvim: https://github.com/nvim-lua/plenary.nvim"
    )
  end

  -- nui.nvim
  if module_exists("nui.popup") then
    health.ok("nui.nvim installed")
  else
    health.error(
      "nui.nvim not found",
      "Install nui.nvim: https://github.com/MunifTanjim/nui.nvim"
    )
  end

  -- Optional: toggleterm.nvim
  if module_exists("toggleterm") then
    health.ok("toggleterm.nvim installed (optional)")
  else
    health.info("toggleterm.nvim not installed (optional, for terminal provider)")
  end

  -- Optional: nvim-treesitter
  if module_exists("nvim-treesitter") then
    health.ok("nvim-treesitter installed (optional)")
  else
    health.info("nvim-treesitter not installed (optional, for better context)")
  end

  -- Check git
  health.start("Git")
  if command_exists("git") then
    local version = get_git_version()
    if version then
      health.ok(version)
    else
      health.ok("Git installed")
    end

    -- Check if in git repo
    local handle = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
    if handle then
      local output = handle:read("*a")
      handle:close()
      if vim.trim(output) == "true" then
        health.ok("Current directory is a git repository")
      else
        health.info("Current directory is not a git repository")
      end
    end
  else
    health.warn(
      "Git not found",
      "Git is recommended for full functionality"
    )
  end

  -- Check MCP server port availability
  health.start("MCP Server")

  local config_ok, prism_config = pcall(require, "prism.config")
  local port_range = { 9100, 9199 }

  if config_ok then
    local mcp_config = prism_config.get("mcp") or {}
    if mcp_config.port_range then
      port_range = mcp_config.port_range
    end
  end

  local available_port = find_available_port(port_range[1], port_range[2])
  if available_port then
    health.ok(string.format(
      "Port available for MCP server: %d (range %d-%d)",
      available_port,
      port_range[1],
      port_range[2]
    ))
  else
    health.warn(
      string.format("No available ports in range %d-%d", port_range[1], port_range[2]),
      "MCP server may not be able to start. Check for conflicting services."
    )
  end

  -- Check prism modules
  health.start("Prism Modules")

  local modules = {
    "prism.config",
    "prism.event",
    "prism.actions",
    "prism.cost",
    "prism.memory",
    "prism.session",
    "prism.selection",
    "prism.send",
  }

  local all_ok = true
  for _, mod in ipairs(modules) do
    if module_exists(mod) then
      health.ok(mod .. " loaded")
    else
      health.warn(mod .. " not found")
      all_ok = false
    end
  end

  if all_ok then
    health.ok("All core modules available")
  end
end

return M
