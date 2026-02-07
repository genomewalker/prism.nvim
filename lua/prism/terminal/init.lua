--- prism.nvim terminal management
--- Orchestrates terminal providers and builds Claude CLI commands
--- @module prism.terminal

local M = {}

--- Provider modules
local providers = {
  snacks = nil,
  native = nil,
  tmux = nil,
}

--- Current active provider
--- @type table|nil
local active_provider = nil

--- Terminal configuration
--- @type table
local config = {}

--- MCP SSE port for IDE integration
--- @type number|nil
local sse_port = nil

--- Load provider modules lazily
--- @param name string Provider name
--- @return table|nil provider
local function get_provider(name)
  if providers[name] then
    return providers[name]
  end

  local ok, provider = pcall(require, "prism.terminal.provider_" .. name)
  if ok then
    providers[name] = provider
    return provider
  end

  return nil
end

--- Select best available provider
--- @param preferred string|nil Preferred provider name
--- @return table|nil provider
local function select_provider(preferred)
  -- Try preferred provider first
  if preferred then
    local provider = get_provider(preferred)
    if provider and provider.is_available() then
      return provider
    end
  end

  -- Try snacks first (better UI)
  local snacks = get_provider("snacks")
  if snacks and snacks.is_available() then
    return snacks
  end

  -- Fall back to native
  local native = get_provider("native")
  if native and native.is_available() then
    return native
  end

  return nil
end

--- Get Claude flags from Neovim command line arguments
--- Everything after "--" is passed directly to Claude:
---   nvim -- --model opus --continue --chrome
---   nvim file.py -- --resume abc123
--- @return string[] flags Raw flags to pass to Claude
local function get_cli_flags()
  local args = vim.v.argv
  local flags = {}
  local found_separator = false

  for _, arg in ipairs(args) do
    if arg == "--" then
      found_separator = true
    elseif found_separator then
      table.insert(flags, arg)
    end
  end

  return flags
end

--- Cached CLI flags (parsed once at startup)
local cli_flags_cache = nil

--- Get CLI flags (cached)
local function get_cached_cli_flags()
  if cli_flags_cache == nil then
    cli_flags_cache = get_cli_flags()
  end
  return cli_flags_cache
end

--- Build Claude CLI command from configuration
--- Priority: CLI flags (after --) > env vars > opts > config
--- Usage: nvim -- --model opus --continue --chrome
--- @param opts table|nil Override options
--- @return string[] cmd Command array
local function build_command(opts)
  opts = opts or {}
  local prism_config = require("prism.config")
  local claude_cfg = prism_config.get("claude") or {}

  local cmd = { claude_cfg.cmd or config.cmd or "claude" }

  -- Model override (env > opts > config)
  local model = vim.env.CLAUDE_MODEL or opts.model or claude_cfg.model
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  -- Continue session (env > opts > config)
  local continue_session = vim.env.CLAUDE_CONTINUE == "1" or vim.env.CLAUDE_CONTINUE == "true"
    or opts.continue_session or claude_cfg.continue_session
  if continue_session then
    table.insert(cmd, "--continue")
  end

  -- Resume specific session (env > opts > config)
  local resume = vim.env.CLAUDE_RESUME or opts.resume or claude_cfg.resume
  if resume then
    table.insert(cmd, "--resume")
    table.insert(cmd, resume)
  end

  -- Chrome integration (env > opts > config)
  local chrome = vim.env.CLAUDE_CHROME == "1" or vim.env.CLAUDE_CHROME == "true"
    or opts.chrome or claude_cfg.chrome
  if chrome then
    table.insert(cmd, "--chrome")
  end

  -- Verbose mode (env > opts > config)
  local verbose = vim.env.CLAUDE_VERBOSE == "1" or vim.env.CLAUDE_VERBOSE == "true"
    or opts.verbose or claude_cfg.verbose
  if verbose then
    table.insert(cmd, "--verbose")
  end

  -- Permission mode (env > opts > config)
  local permission_mode = vim.env.CLAUDE_PERMISSION_MODE or opts.permission_mode or claude_cfg.permission_mode
  if permission_mode then
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, permission_mode)
  end

  -- Dangerously skip permissions (env > opts > config)
  local skip_perms = vim.env.CLAUDE_SKIP_PERMISSIONS == "1" or vim.env.CLAUDE_SKIP_PERMISSIONS == "true"
    or opts.dangerously_skip_permissions or claude_cfg.dangerously_skip_permissions
  if skip_perms then
    table.insert(cmd, "--dangerously-skip-permissions")
  end

  -- Custom flags from env (space-separated)
  -- Support both CLAUDE_ARGS (from nvc function) and CLAUDE_FLAGS
  local env_flags = vim.env.CLAUDE_ARGS or vim.env.CLAUDE_FLAGS
  if env_flags and env_flags ~= "" then
    for flag in env_flags:gmatch("%S+") do
      table.insert(cmd, flag)
    end
  end

  -- Custom flags from config
  local custom_flags = opts.custom_flags or claude_cfg.custom_flags or {}
  for _, flag in ipairs(custom_flags) do
    table.insert(cmd, flag)
  end

  -- CLI flags (highest priority - everything after "nvim --")
  local cli_flags = get_cached_cli_flags()
  for _, flag in ipairs(cli_flags) do
    table.insert(cmd, flag)
  end

  return cmd
end

--- Build environment variables for terminal
--- @param opts table|nil Override options
--- @return table env Environment variables
local function build_env(opts)
  opts = opts or {}
  local env = {}

  -- Set SSE port for MCP integration
  if sse_port then
    env.CLAUDE_CODE_SSE_PORT = tostring(sse_port)
  elseif opts.sse_port then
    env.CLAUDE_CODE_SSE_PORT = tostring(opts.sse_port)
  end

  -- Enable IDE integration
  env.ENABLE_IDE_INTEGRATION = "true"

  -- Merge any additional env vars
  if opts.env then
    env = vim.tbl_extend("force", env, opts.env)
  end

  return env
end

--- Setup terminal module
--- @param opts table|nil Configuration options
function M.setup(opts)
  opts = opts or {}
  local prism_config = require("prism.config")
  local term_cfg = prism_config.get("terminal") or {}

  config = vim.tbl_extend("force", {
    provider = "native",
    position = "vertical",
    width = 0.4,
    height = 0.3,
    cmd = "claude",
    auto_start = false,
  }, term_cfg, opts)

  -- Select provider
  active_provider = select_provider(config.provider)

  if not active_provider then
    vim.notify("[prism.nvim] No terminal provider available", vim.log.levels.WARN)
  end

  -- Setup terminal mode
  if config.passthrough then
    -- Clean passthrough mode: only Ctrl+\ Ctrl+\ exits
    local ok, passthrough = pcall(require, "prism.terminal.passthrough")
    if ok then
      passthrough.enable_global()
    end
  else
    -- Standard keymaps with Neovim integration
    local ok, keymaps = pcall(require, "prism.terminal.keymaps")
    if ok then
      keymaps.setup()
    end
  end
end

--- Set MCP SSE port
--- @param port number Port number
function M.set_sse_port(port)
  sse_port = port
end

--- Get current SSE port
--- @return number|nil port
function M.get_sse_port()
  return sse_port
end

--- Open Claude terminal
--- @param opts table|nil Options { model, continue_session, resume, cwd, on_exit, on_open }
--- @return boolean success
function M.open(opts)
  opts = opts or {}

  if not active_provider then
    active_provider = select_provider(config.provider)
    if not active_provider then
      vim.notify("[prism.nvim] No terminal provider available", vim.log.levels.ERROR)
      return false
    end
  end

  local cmd = build_command(opts)
  local env = build_env(opts)

  local term_opts = {
    cwd = opts.cwd or vim.fn.getcwd(),
    position = opts.position or config.position,
    width = opts.width or config.width,
    height = opts.height or config.height,
    border = opts.border or "rounded",
    title = opts.title or " Claude Code ",
    on_exit = opts.on_exit,
    on_open = function(terminal)
      -- Emit event
      local event = require("prism.event")
      event.emit(event.events.TERMINAL_OPENED, {
        provider = config.provider,
        cmd = cmd,
        cwd = opts.cwd or vim.fn.getcwd(),
      })

      if opts.on_open then
        opts.on_open(terminal)
      end
    end,
  }

  local success = active_provider.open(cmd, env, term_opts)

  return success
end

--- Close Claude terminal
--- @return boolean success
function M.close()
  if not active_provider then
    return false
  end

  local success = active_provider.close()

  if success then
    local event = require("prism.event")
    event.emit(event.events.TERMINAL_CLOSED, {})
  end

  return success
end

--- Toggle terminal visibility
--- @return boolean visible New visibility state
function M.toggle()
  if not active_provider then
    -- Try to open if no terminal exists
    return M.open()
  end

  local bufnr = active_provider.get_bufnr()
  if not bufnr then
    -- No terminal exists, open one
    return M.open()
  end

  return active_provider.toggle()
end

--- Send text to terminal
--- @param text string Text to send
--- @return boolean success
function M.send(text)
  if not active_provider then
    return false
  end

  local success = active_provider.send(text)

  if success then
    local event = require("prism.event")
    event.emit(event.events.MESSAGE_SENT, {
      text = text,
      timestamp = vim.loop.hrtime() / 1e6,
    })
  end

  return success
end

--- Send text with newline (like pressing enter)
--- @param text string Text to send
--- @return boolean success
function M.send_line(text)
  return M.send(text .. "\n")
end

--- Restart terminal with same configuration
--- @param opts table|nil New options to apply
--- @return boolean success
function M.restart(opts)
  M.close()
  vim.defer_fn(function()
    M.open(opts)
  end, 100) -- Small delay to ensure cleanup
  return true
end

--- Get terminal buffer number
--- @return number|nil bufnr
function M.get_bufnr()
  if not active_provider then
    return nil
  end
  return active_provider.get_bufnr()
end

--- Check if terminal is visible
--- @return boolean
function M.is_visible()
  if not active_provider then
    return false
  end
  return active_provider.is_visible()
end

--- Check if terminal is running
--- @return boolean
function M.is_running()
  if not active_provider then
    return false
  end

  -- Check if provider has is_running method
  if active_provider.is_running then
    return active_provider.is_running()
  end

  -- Fall back to checking buffer existence
  return active_provider.get_bufnr() ~= nil
end

--- Get current provider name
--- @return string|nil provider_name
function M.get_provider_name()
  if not active_provider then
    return nil
  end

  for name, provider in pairs(providers) do
    if provider == active_provider then
      return name
    end
  end

  return nil
end

--- Get available providers
--- @return string[] providers List of available provider names
function M.available_providers()
  local available = {}
  for _, name in ipairs({ "snacks", "native" }) do
    local provider = get_provider(name)
    if provider and provider.is_available() then
      table.insert(available, name)
    end
  end
  return available
end

--- Switch to a different provider
--- @param name string Provider name
--- @return boolean success
function M.switch_provider(name)
  local provider = get_provider(name)
  if not provider or not provider.is_available() then
    vim.notify("[prism.nvim] Provider '" .. name .. "' not available", vim.log.levels.ERROR)
    return false
  end

  -- Close existing terminal
  if active_provider then
    active_provider.close()
  end

  active_provider = provider
  config.provider = name
  return true
end

--- Focus the terminal window
--- @return boolean success
function M.focus()
  if not active_provider then
    return false
  end

  local bufnr = active_provider.get_bufnr()
  if not bufnr then
    return false
  end

  -- Find window containing the buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
      return true
    end
  end

  return false
end

return M
