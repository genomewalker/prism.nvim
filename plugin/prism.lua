--- prism.nvim plugin loader
--- Supports two modes:
---   1. Simple: require("prism.core").setup() - minimal integration
---   2. Full:   require("prism").setup()      - all features

-- Prevent loading twice
if vim.g.loaded_prism then
  return
end
vim.g.loaded_prism = true

-- Check Neovim version
if vim.fn.has("nvim-0.9.0") ~= 1 then
  vim.api.nvim_err_writeln("prism.nvim requires Neovim >= 0.9.0")
  return
end

-- Check if user wants simple mode (set before loading plugin)
-- Usage: vim.g.prism_simple = true before loading
if vim.g.prism_simple then
  require("prism.core").setup(vim.g.prism_config or {})
  return
end

-- Create lazy-loading :Prism command
-- This gets replaced by the real command when setup() is called
vim.api.nvim_create_user_command("Prism", function(opts)
  -- Load and setup the plugin
  local prism = require("prism")

  -- Initialize with default config if not already done
  if not prism.is_initialized() then
    prism.setup()
  end

  -- Re-run the command now that plugin is loaded
  if opts.args and opts.args ~= "" then
    vim.cmd("Prism " .. opts.args)
  else
    vim.cmd("Prism toggle")
  end
end, {
  nargs = "*",
  complete = function()
    return {
      "toggle",
      "open",
      "close",
      "chat",
      "send",
      "actions",
      "model",
      "diff",
      "history",
      "stop",
      "version",
      "health",
    }
  end,
  desc = "Prism Claude Code integration",
})

-- Additional subcommands for the full :Prism command
-- These get properly defined when prism.setup() creates the real command
local subcommand_completions = {
  "toggle", "open", "close",
  "chat", "send",
  "actions", "explain", "fix", "review", "test", "docs", "refactor",
  "diff", "accept", "reject", "next", "prev",
  "model",
  "history", "session",
  "mcp",
  "cost",
  "stop",
  "version", "health", "info", "debug",
}

-- Create other lazy commands that trigger setup
local lazy_commands = {
  { name = "PrismChat", args = "?", cmd = "chat" },
  { name = "PrismSend", args = "+", cmd = "send" },
  { name = "PrismActions", args = 0, cmd = "actions" },
  { name = "PrismAction", args = 0, cmd = "actions" },
  { name = "PrismDiff", args = 0, cmd = "diff" },
  { name = "PrismStop", args = 0, cmd = "stop" },
  { name = "PrismToggle", args = 0, cmd = "toggle" },
  { name = "PrismResize", args = 0, cmd = "resize" },
  { name = "PrismModel", args = "?", cmd = "model" },
  { name = "PrismAccept", args = 0, cmd = "accept" },
  { name = "PrismReject", args = 0, cmd = "reject" },
  { name = "PrismAcceptAll", args = 0, cmd = "accept_all" },
  { name = "PrismRejectAll", args = 0, cmd = "reject_all" },
  { name = "PrismCost", args = 0, cmd = "cost" },
  { name = "PrismSession", args = "?", cmd = "session" },
}

for _, cmd in ipairs(lazy_commands) do
  vim.api.nvim_create_user_command(cmd.name, function(opts)
    local prism = require("prism")
    if not prism.is_initialized() then
      prism.setup()
    end

    if cmd.args == 0 then
      vim.cmd("Prism " .. cmd.cmd)
    else
      vim.cmd("Prism " .. cmd.cmd .. " " .. (opts.args or ""))
    end
  end, {
    nargs = cmd.args,
    desc = "Prism " .. cmd.cmd,
  })
end
