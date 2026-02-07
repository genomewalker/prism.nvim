--- prism.nvim send module
--- Orchestrate sending content to Claude
--- @module prism.send

local M = {}

local config = require("prism.config")
local event = require("prism.event")
local selection = require("prism.selection")

--- Terminal reference (set by terminal module)
--- @type table|nil
local terminal = nil

--- Set terminal module reference
--- @param term table Terminal module
function M.set_terminal(term)
  terminal = term
end

--- Send text to Claude terminal
--- @param text string Text to send
--- @param opts table|nil Options {newline}
--- @return boolean success
local function send_to_terminal(text, opts)
  opts = opts or {}

  if not terminal then
    -- Try to require terminal module
    local ok, term = pcall(require, "prism.terminal")
    if ok then
      terminal = term
    else
      vim.notify("[prism] Terminal module not available", vim.log.levels.ERROR)
      return false
    end
  end

  -- Ensure terminal is open
  if not terminal.is_open() then
    terminal.open()
    -- Give terminal time to initialize
    vim.defer_fn(function()
      terminal.send(text)
    end, 100)
    return true
  end

  terminal.send(text)
  return true
end

--- Format file reference as @mention
--- @param path string File path
--- @param start_line number|nil Start line
--- @param end_line number|nil End line
--- @return string Formatted reference
local function format_file_ref(path, start_line, end_line)
  local relative = vim.fn.fnamemodify(path, ":~:.")

  if start_line and end_line and start_line ~= end_line then
    return string.format("@%s:%d-%d", relative, start_line, end_line)
  elseif start_line then
    return string.format("@%s:%d", relative, start_line)
  else
    return "@" .. relative
  end
end

--- Send current visual selection to Claude
--- @param opts table|nil Options {with_context}
--- @return boolean success
function M.selection(opts)
  opts = opts or {}

  local sel = selection.get_latest()
  if not sel or not sel.text or sel.text == "" then
    vim.notify("[prism] No selection available", vim.log.levels.WARN)
    return false
  end

  local text
  if opts.with_context then
    -- Include file context
    local file_ref = format_file_ref(sel.file, sel.start_line, sel.end_line)
    text = string.format(
      "%s\n```%s\n%s\n```",
      file_ref,
      sel.filetype or "",
      sel.text
    )
  else
    text = sel.text
  end

  event.emit("send:selection", { selection = sel })
  return send_to_terminal(text)
end

--- Send file as @mention reference
--- @param path string|nil File path (uses current buffer if nil)
--- @return boolean success
function M.file(path)
  path = path or vim.fn.expand("%:p")

  if not path or path == "" then
    vim.notify("[prism] No file specified", vim.log.levels.WARN)
    return false
  end

  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("[prism] File not found: " .. path, vim.log.levels.ERROR)
    return false
  end

  local ref = format_file_ref(path)
  event.emit("send:file", { path = path })
  return send_to_terminal(ref)
end

--- Send entire current buffer content
--- @param opts table|nil Options {with_context}
--- @return boolean success
function M.buffer(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  if content == "" then
    vim.notify("[prism] Buffer is empty", vim.log.levels.WARN)
    return false
  end

  local text
  if opts.with_context ~= false then
    local file = vim.fn.expand("%:p")
    local filetype = vim.bo[bufnr].filetype
    local file_ref = format_file_ref(file)
    text = string.format(
      "%s\n```%s\n%s\n```",
      file_ref,
      filetype or "",
      content
    )
  else
    text = content
  end

  event.emit("send:buffer", { bufnr = bufnr })
  return send_to_terminal(text)
end

--- Prompt user for input and send to Claude
--- @param prompt string|nil Input prompt
--- @param opts table|nil Options
--- @return boolean success (always returns true, async operation)
function M.ask(prompt, opts)
  opts = opts or {}
  prompt = prompt or "Ask Claude:"

  vim.ui.input({ prompt = prompt .. " " }, function(input)
    if input and input ~= "" then
      event.emit("send:ask", { prompt = input })
      send_to_terminal(input)
    end
  end)

  return true
end

--- Add file range to context (send as reference)
--- @param file string|nil File path
--- @param start_line number|nil Start line
--- @param end_line number|nil End line
--- @return boolean success
function M.add(file, start_line, end_line)
  file = file or vim.fn.expand("%:p")

  if not file or file == "" then
    vim.notify("[prism] No file specified", vim.log.levels.WARN)
    return false
  end

  local ref = format_file_ref(file, start_line, end_line)

  -- If lines specified, include the content
  if start_line and end_line then
    local lines = vim.fn.readfile(file)
    if #lines == 0 then
      vim.notify("[prism] Could not read file", vim.log.levels.ERROR)
      return false
    end

    -- Extract range
    local range_lines = {}
    for i = start_line, math.min(end_line, #lines) do
      table.insert(range_lines, lines[i])
    end

    local filetype = vim.filetype.match({ filename = file }) or ""
    local text = string.format(
      "%s\n```%s\n%s\n```",
      ref,
      filetype,
      table.concat(range_lines, "\n")
    )

    event.emit("send:add", { file = file, start_line = start_line, end_line = end_line })
    return send_to_terminal(text)
  end

  event.emit("send:add", { file = file })
  return send_to_terminal(ref)
end

--- Send raw text to Claude
--- @param text string Text to send
--- @return boolean success
function M.text(text)
  if not text or text == "" then
    return false
  end

  event.emit("send:text", { text = text })
  return send_to_terminal(text)
end

--- Send action result to Claude
--- @param action_result table Result from actions.run()
--- @return boolean success
function M.action(action_result)
  if not action_result or not action_result.prompt then
    vim.notify("[prism] Invalid action result", vim.log.levels.ERROR)
    return false
  end

  event.emit("send:action", { action = action_result.action })
  return send_to_terminal(action_result.prompt)
end

--- Send diagnostics for current line/buffer
--- @param opts table|nil Options {line, buffer}
--- @return boolean success
function M.diagnostics(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_get_current_buf()
  local diagnostics

  if opts.line then
    local lnum = opts.line == true and vim.fn.line(".") - 1 or opts.line - 1
    diagnostics = vim.diagnostic.get(bufnr, { lnum = lnum })
  else
    diagnostics = vim.diagnostic.get(bufnr)
  end

  if #diagnostics == 0 then
    vim.notify("[prism] No diagnostics found", vim.log.levels.INFO)
    return false
  end

  local file = vim.fn.expand("%:p")
  local lines = { format_file_ref(file), "", "Diagnostics:" }

  for _, d in ipairs(diagnostics) do
    local severity = vim.diagnostic.severity[d.severity] or "UNKNOWN"
    table.insert(lines, string.format(
      "- Line %d: [%s] %s",
      d.lnum + 1,
      severity,
      d.message
    ))
  end

  local text = table.concat(lines, "\n")
  event.emit("send:diagnostics", { count = #diagnostics })
  return send_to_terminal(text)
end

return M
