--- prism.nvim - The ultimate Claude Code Neovim plugin
--- @module prism

local M = {}

--- Plugin version
M.version = {
  major = 0,
  minor = 1,
  patch = 0,
}

--- Get version string
--- @return string Version in semver format
function M.version_string()
  return string.format("%d.%d.%d", M.version.major, M.version.minor, M.version.patch)
end

--- Plugin state
local state = {
  initialized = false,
  terminal_open = false,
}

--- Highlight groups
local highlights = {
  PrismBorder = { link = "FloatBorder" },
  PrismTitle = { link = "Title" },
  PrismNormal = { link = "NormalFloat" },
  PrismCursorLine = { link = "CursorLine" },
  PrismSelection = { link = "Visual" },
  PrismDiffAdd = { link = "DiffAdd" },
  PrismDiffDelete = { link = "DiffDelete" },
  PrismDiffChange = { link = "DiffChange" },
  PrismDiffText = { link = "DiffText" },
  PrismIcon = { fg = "#cc9966" },
  PrismCost = { fg = "#888888" },
  PrismModel = { fg = "#66aacc" },
  PrismSpinner = { fg = "#cccc66" },
  PrismSuccess = { fg = "#66cc66" },
  PrismError = { fg = "#cc6666" },
  PrismWarning = { fg = "#ccaa66" },
  PrismInfo = { fg = "#6699cc" },
}

--- Register highlight groups
local function setup_highlights()
  for name, opts in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

--- Register user commands
local function setup_commands()
  -- Main toggle command
  vim.api.nvim_create_user_command("Prism", function(opts)
    local subcmd = opts.fargs[1] or "toggle"
    local args = vim.list_slice(opts.fargs, 2)

    if subcmd == "toggle" then
      M.toggle()
    elseif subcmd == "open" then
      M.open()
    elseif subcmd == "close" then
      M.close()
    elseif subcmd == "chat" then
      M.chat(table.concat(args, " "))
    elseif subcmd == "send" then
      M.send(table.concat(args, " "))
    elseif subcmd == "actions" then
      M.actions()
    elseif subcmd == "model" then
      M.model(args[1])
    elseif subcmd == "diff" then
      M.diff()
    elseif subcmd == "history" then
      M.history()
    elseif subcmd == "stop" then
      M.stop()
    elseif subcmd == "accept" then
      M.accept_hunk()
    elseif subcmd == "reject" then
      M.reject_hunk()
    elseif subcmd == "accept_all" then
      M.accept_all()
    elseif subcmd == "reject_all" then
      M.reject_all()
    elseif subcmd == "cost" then
      M.cost()
    elseif subcmd == "session" then
      M.session(args[1])
    elseif subcmd == "version" then
      vim.notify("prism.nvim v" .. M.version_string(), vim.log.levels.INFO)
    elseif subcmd == "health" then
      vim.cmd("checkhealth prism")
    else
      vim.notify("Unknown subcommand: " .. subcmd, vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(_, cmdline, _)
      local args = vim.split(cmdline, "%s+")
      if #args <= 2 then
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
          "accept",
          "reject",
          "accept_all",
          "reject_all",
          "cost",
          "session",
          "version",
          "health",
        }
      end
      return {}
    end,
    desc = "Prism Claude Code integration",
  })

  -- Convenience commands
  vim.api.nvim_create_user_command("PrismChat", function(opts)
    M.chat(opts.args)
  end, { nargs = "?", desc = "Open Prism chat" })

  vim.api.nvim_create_user_command("PrismSend", function(opts)
    M.send(opts.args)
  end, { nargs = "+", desc = "Send message to Claude" })

  vim.api.nvim_create_user_command("PrismActions", function()
    M.actions()
  end, { desc = "Open Prism actions menu" })

  vim.api.nvim_create_user_command("PrismDiff", function()
    M.diff()
  end, { desc = "Show diff for current file" })

  vim.api.nvim_create_user_command("PrismStop", function()
    M.stop()
  end, { desc = "Stop current Claude operation" })

  vim.api.nvim_create_user_command("PrismToggle", function()
    M.toggle()
  end, { desc = "Toggle Prism terminal" })

  vim.api.nvim_create_user_command("PrismModel", function(opts)
    M.model(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Switch Claude model" })

  vim.api.nvim_create_user_command("PrismAccept", function()
    M.accept_hunk()
  end, { desc = "Accept current diff hunk" })

  vim.api.nvim_create_user_command("PrismReject", function()
    M.reject_hunk()
  end, { desc = "Reject current diff hunk" })

  vim.api.nvim_create_user_command("PrismAcceptAll", function()
    M.accept_all()
  end, { desc = "Accept all diff hunks" })

  vim.api.nvim_create_user_command("PrismRejectAll", function()
    M.reject_all()
  end, { desc = "Reject all diff hunks" })

  vim.api.nvim_create_user_command("PrismCost", function()
    M.cost()
  end, { desc = "Show session cost" })

  vim.api.nvim_create_user_command("PrismSession", function(opts)
    M.session(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Session management" })

  vim.api.nvim_create_user_command("PrismAction", function()
    M.actions()
  end, { desc = "Open Prism actions menu" })

  vim.api.nvim_create_user_command("PrismTimeline", function()
    M.timeline()
  end, { desc = "Show edit timeline" })

  vim.api.nvim_create_user_command("PrismFreeze", function()
    M.freeze()
  end, { desc = "Toggle freeze (guardian mode)" })
end

--- Register keymaps from config
local function setup_keymaps()
  local config = require("prism.config")
  local keymaps = config.get("keymaps")

  if not keymaps then
    return
  end

  local mappings = {
    { key = "toggle", fn = M.toggle, desc = "Toggle Prism terminal" },
    { key = "chat", fn = M.chat, desc = "Open Prism chat" },
    { key = "actions", fn = M.actions, desc = "Open actions menu" },
    { key = "diff", fn = M.diff, desc = "Show file diff" },
    { key = "model", fn = M.model, desc = "Switch model" },
    { key = "history", fn = M.history, desc = "Show session history" },
    { key = "stop", fn = M.stop, desc = "Stop current operation" },
  }

  for _, mapping in ipairs(mappings) do
    local key = keymaps[mapping.key]
    if key and key ~= "" then
      vim.keymap.set("n", key, mapping.fn, {
        desc = "[Prism] " .. mapping.desc,
        silent = true,
      })
    end
  end

  -- Visual mode send
  if keymaps.send and keymaps.send ~= "" then
    vim.keymap.set("v", keymaps.send, function()
      M.send_selection()
    end, {
      desc = "[Prism] Send selection to Claude",
      silent = true,
    })
  end
end

--- Setup cleanup on VimLeave
local function setup_cleanup()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("PrismCleanup", { clear = true }),
    callback = function()
      -- Close terminal gracefully
      pcall(function()
        local terminal = require("prism.terminal")
        terminal.close()
      end)

      -- Stop MCP server
      pcall(function()
        local mcp = require("prism.mcp")
        mcp.stop()
      end)

      -- Emit shutdown event
      pcall(function()
        local event = require("prism.event")
        event.emit(event.events.PLUGIN_UNLOADED, {})
      end)
    end,
  })
end

--- Setup the plugin
--- @param opts table|nil User configuration options
function M.setup(opts)
  if state.initialized then
    return
  end

  -- 1. Setup configuration
  local config = require("prism.config")
  config.setup(opts)

  -- 2. Clear event bus
  local event = require("prism.event")
  event.clear()

  -- 3. Register highlights
  setup_highlights()

  -- Re-apply highlights on colorscheme change
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("PrismHighlights", { clear = true }),
    callback = setup_highlights,
  })

  -- 4. Initialize modules
  local util = require("prism.util")

  -- Terminal
  pcall(function()
    local terminal = require("prism.terminal")
    terminal.setup()
  end)

  -- MCP server and tools
  pcall(function()
    local tools = require("prism.mcp.tools")
    tools.load_builtins()
  end)

  if config.get("mcp.auto_start") then
    pcall(function()
      local mcp = require("prism.mcp")
      mcp.start()
    end)
  end

  -- Selection tracking
  pcall(function()
    local selection = require("prism.mcp.tools.get_selection")
    selection.setup_tracking()
  end)

  -- Diff engine
  pcall(function()
    local diff = require("prism.diff")
    diff.setup()
  end)

  -- Companion mode (trust-based edit handling)
  pcall(function()
    local companion = require("prism.companion")
    companion.setup()
  end)

  -- UI components
  pcall(function()
    local ui = require("prism.ui")
    ui.setup()
  end)

  -- Integrations (tree explorers)
  pcall(function()
    local integrations = require("prism.integrations")
    integrations.setup()
  end)

  -- 5. Register commands
  setup_commands()

  -- 6. Register keymaps
  setup_keymaps()

  -- 7. Setup cleanup
  setup_cleanup()

  -- Mark as initialized
  state.initialized = true

  -- Emit loaded event
  event.emit(event.events.PLUGIN_LOADED, {
    version = M.version_string(),
  })

  -- Auto-start terminal if configured
  if config.get("terminal.auto_start") then
    vim.schedule(function()
      M.open()
    end)
  end

  util.log.debug("prism.nvim initialized", { version = M.version_string() })
end

--- Toggle the Claude terminal
function M.toggle()
  local ok, terminal = pcall(require, "prism.terminal")
  if ok then
    terminal.toggle()
    state.terminal_open = terminal.is_visible()
  end
end

--- Open the Claude terminal
function M.open()
  local ok, terminal = pcall(require, "prism.terminal")
  if ok then
    terminal.open()
    state.terminal_open = true
  end
end

--- Close the Claude terminal
function M.close()
  local ok, terminal = pcall(require, "prism.terminal")
  if ok then
    terminal.close()
    state.terminal_open = false
  end
end

--- Open chat input
--- @param initial_text string|nil Initial text for the chat
function M.chat(initial_text)
  local ok, ui = pcall(require, "prism.ui")
  if ok and ui.chat then
    ui.chat.open(initial_text)
  else
    -- Fallback: just open terminal and focus input
    M.open()
  end
end

--- Send a message to Claude
--- @param message string Message to send
function M.send(message)
  if not message or message == "" then
    return
  end

  local ok, terminal = pcall(require, "prism.terminal")
  if ok then
    terminal.send(message)
  end

  local event = require("prism.event")
  event.emit(event.events.MESSAGE_SENT, { message = message })
end

--- Send the current visual selection
function M.send_selection()
  local util = require("prism.util")
  local lines, range = util.get_visual_selection()

  if #lines == 0 then
    vim.notify("No selection", vim.log.levels.WARN)
    return
  end

  local file_path = vim.api.nvim_buf_get_name(0)
  local filetype = vim.bo.filetype

  -- Format with context
  local context = string.format(
    "File: %s (lines %d-%d)\n```%s\n%s\n```",
    util.relative_path(file_path),
    range[1],
    range[3],
    filetype,
    table.concat(lines, "\n")
  )

  M.send(context)
end

--- Open actions menu
function M.actions()
  local ok, actions = pcall(require, "prism.actions")
  if ok then
    actions.show_menu()
  end
end

--- Show/switch model
--- @param model string|nil Model to switch to
function M.model(model)
  local ok, model_picker = pcall(require, "prism.ui.model_picker")
  if ok then
    if model then
      model_picker.set_current(model)
      require("prism.ui.notify").success("Model set to " .. model)
    else
      model_picker.open()
    end
  else
    vim.notify("[prism.nvim] Model picker not available", vim.log.levels.WARN)
  end
end

--- Show diff for current file
function M.diff()
  local ok, diff = pcall(require, "prism.diff")
  if ok then
    diff.show_current()
  end
end

--- Show session history
function M.history()
  local ok, session = pcall(require, "prism.session")
  if ok then
    session.show_history()
  end
end

--- Stop current operation
function M.stop()
  local ok, terminal = pcall(require, "prism.terminal")
  if ok then
    terminal.interrupt()
  end

  local event = require("prism.event")
  event.emit("operation:stopped", {})
end

--- Accept current diff hunk
function M.accept_hunk()
  local ok, diff_mod = pcall(require, "prism.diff")
  if ok then
    diff_mod.accept_hunk()
  else
    vim.notify("[prism.nvim] Diff module not available", vim.log.levels.WARN)
  end
end

--- Reject current diff hunk
function M.reject_hunk()
  local ok, diff_mod = pcall(require, "prism.diff")
  if ok then
    diff_mod.reject_hunk()
  else
    vim.notify("[prism.nvim] Diff module not available", vim.log.levels.WARN)
  end
end

--- Accept all diff hunks
function M.accept_all()
  local ok, diff_mod = pcall(require, "prism.diff")
  if ok then
    diff_mod.accept_all()
  else
    vim.notify("[prism.nvim] Diff module not available", vim.log.levels.WARN)
  end
end

--- Reject all diff hunks
function M.reject_all()
  local ok, diff_mod = pcall(require, "prism.diff")
  if ok then
    diff_mod.reject_all()
  else
    vim.notify("[prism.nvim] Diff module not available", vim.log.levels.WARN)
  end
end

--- Show cost tracking info
function M.cost()
  local ok, cost_mod = pcall(require, "prism.cost")
  if ok then
    cost_mod.show()
  else
    vim.notify("[prism.nvim] Cost module not available", vim.log.levels.WARN)
  end
end

--- Session management
--- @param subcmd string|nil Subcommand (list, save, load)
function M.session(subcmd)
  local ok, session_mod = pcall(require, "prism.session")
  if ok then
    if subcmd == "list" then
      session_mod.list()
    elseif subcmd == "save" then
      session_mod.save()
    elseif subcmd == "load" or subcmd == "restore" then
      session_mod.restore()
    else
      session_mod.list()
    end
  else
    vim.notify("[prism.nvim] Session module not available", vim.log.levels.WARN)
  end
end

--- Show edit timeline (companion mode)
function M.timeline()
  local ok, timeline = pcall(require, "prism.ui.timeline")
  if ok then
    timeline.open()
  else
    vim.notify("[prism.nvim] Timeline not available", vim.log.levels.WARN)
  end
end

--- Toggle freeze (switch to guardian mode)
function M.freeze()
  local ok, companion = pcall(require, "prism.companion")
  if ok then
    local status = companion.get_status()
    if status.frozen then
      companion.unfreeze()
    else
      companion.freeze()
    end
  end
end

--- Check if plugin is initialized
--- @return boolean
function M.is_initialized()
  return state.initialized
end

--- Check if terminal is open
--- @return boolean
function M.is_open()
  return state.terminal_open
end

--- Public API - expose sub-modules
M.config = require("prism.config")
M.event = require("prism.event")
M.util = require("prism.util")

-- Lazy-load sub-modules
setmetatable(M, {
  __index = function(_, key)
    local submodules = {
      terminal = "prism.terminal",
      mcp = "prism.mcp",
      tools = "prism.mcp.tools",
      diff = "prism.diff",
      ui = "prism.ui",
      actions = "prism.actions",
      session = "prism.session",
      memory = "prism.memory",
      cost = "prism.cost",
      git = "prism.git",
      lsp = "prism.lsp",
      integrations = "prism.integrations",
      companion = "prism.companion",
      review = "prism.review",
    }

    if submodules[key] then
      local ok, mod = pcall(require, submodules[key])
      if ok then
        return mod
      end
    end
    return nil
  end,
})

return M
