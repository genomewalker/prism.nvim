--- prism.nvim LSP code actions integration
--- Get and apply code actions, merge with prism actions
--- @module prism.lsp.code_actions

local M = {}

--- Get code actions for a buffer and range
--- @param bufnr number|nil Buffer number (default: current)
--- @param range table|nil Range { start = {line, col}, end = {line, col} } (0-indexed)
--- @param callback function|nil Callback function(actions) - if nil, returns synchronously
--- @return table[]|nil actions Code actions (only if callback is nil and synchronous)
function M.get_actions(bufnr, range, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Get line range
  local start_line, end_line
  if range then
    start_line = range.start[1]
    end_line = range["end"][1]
  else
    -- Use current cursor position
    local cursor = vim.api.nvim_win_get_cursor(0)
    start_line = cursor[1] - 1 -- 0-indexed
    end_line = start_line
  end

  -- Build params
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      start = { line = start_line, character = 0 },
      ["end"] = { line = end_line + 1, character = 0 },
    },
    context = {
      diagnostics = vim.diagnostic.get(bufnr, {
        lnum = start_line,
      }),
      only = nil, -- Get all kinds
      triggerKind = vim.lsp.protocol.CodeActionTriggerKind.Invoked,
    },
  }

  -- Async request
  if callback then
    vim.lsp.buf_request_all(bufnr, "textDocument/codeAction", params, function(results)
      local actions = {}
      for _, result in pairs(results or {}) do
        if result.result then
          for _, action in ipairs(result.result) do
            table.insert(actions, action)
          end
        end
      end
      callback(actions)
    end)
    return nil
  end

  -- Synchronous request
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/codeAction", params, 1000)
  local actions = {}

  if results then
    for _, result in pairs(results) do
      if result.result then
        for _, action in ipairs(result.result) do
          table.insert(actions, action)
        end
      end
    end
  end

  return actions
end

--- Apply a code action
--- @param action table The code action to apply
--- @param bufnr number|nil Buffer number
--- @return boolean success
function M.apply(action, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not action then
    return false
  end

  -- Handle command
  if action.command then
    local command = action.command
    if type(command) == "string" then
      vim.lsp.buf.execute_command({ command = command })
    else
      vim.lsp.buf.execute_command(command)
    end
    return true
  end

  -- Handle edit
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, "utf-8")
    return true
  end

  return false
end

--- Create a prism action structure
--- @param title string Action title
--- @param kind string|nil Action kind
--- @param handler function Action handler function
--- @return table action
function M.create_prism_action(title, kind, handler)
  return {
    title = title,
    kind = kind or "prism",
    is_prism = true,
    handler = handler,
  }
end

--- Merge LSP actions with prism actions
--- @param lsp_actions table[] LSP code actions
--- @param prism_actions table[] Prism custom actions
--- @param opts table|nil Options { prism_first = boolean, separator = boolean }
--- @return table[] merged Merged actions list
function M.merge_with_prism(lsp_actions, prism_actions, opts)
  opts = opts or {}
  local result = {}

  if opts.prism_first then
    -- Prism actions first
    for _, action in ipairs(prism_actions or {}) do
      table.insert(result, action)
    end

    -- Add separator if both have items
    if #result > 0 and #(lsp_actions or {}) > 0 and opts.separator then
      table.insert(result, {
        title = "─── LSP Actions ───",
        is_separator = true,
      })
    end

    for _, action in ipairs(lsp_actions or {}) do
      table.insert(result, action)
    end
  else
    -- LSP actions first (default)
    for _, action in ipairs(lsp_actions or {}) do
      table.insert(result, action)
    end

    if #result > 0 and #(prism_actions or {}) > 0 and opts.separator then
      table.insert(result, {
        title = "─── Prism Actions ───",
        is_separator = true,
      })
    end

    for _, action in ipairs(prism_actions or {}) do
      table.insert(result, action)
    end
  end

  return result
end

--- Execute an action (handles both LSP and prism actions)
--- @param action table The action to execute
--- @param bufnr number|nil Buffer number
--- @return boolean success
function M.execute(action, bufnr)
  if not action then
    return false
  end

  -- Skip separators
  if action.is_separator then
    return false
  end

  -- Handle prism custom actions
  if action.is_prism and action.handler then
    local ok, err = pcall(action.handler, bufnr)
    if not ok then
      vim.notify("[prism.nvim] Action error: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    return true
  end

  -- Handle LSP actions
  return M.apply(action, bufnr)
end

--- Get quick fix actions (errors/warnings only)
--- @param bufnr number|nil Buffer number
--- @param callback function|nil Callback
--- @return table[]|nil actions
function M.get_quickfix_actions(bufnr, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Get cursor position
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      start = { line = line, character = 0 },
      ["end"] = { line = line + 1, character = 0 },
    },
    context = {
      diagnostics = vim.diagnostic.get(bufnr, { lnum = line }),
      only = { "quickfix" },
      triggerKind = vim.lsp.protocol.CodeActionTriggerKind.Invoked,
    },
  }

  if callback then
    vim.lsp.buf_request_all(bufnr, "textDocument/codeAction", params, function(results)
      local actions = {}
      for _, result in pairs(results or {}) do
        if result.result then
          for _, action in ipairs(result.result) do
            table.insert(actions, action)
          end
        end
      end
      callback(actions)
    end)
    return nil
  end

  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/codeAction", params, 1000)
  local actions = {}

  if results then
    for _, result in pairs(results) do
      if result.result then
        for _, action in ipairs(result.result) do
          table.insert(actions, action)
        end
      end
    end
  end

  return actions
end

--- Format actions for display in picker
--- @param actions table[] Actions list
--- @return table[] formatted { display, action }
function M.format_for_picker(actions)
  local result = {}

  for _, action in ipairs(actions) do
    local icon = ""

    if action.is_separator then
      icon = ""
    elseif action.is_prism then
      icon = "󰚩"
    elseif action.kind then
      if action.kind:match("quickfix") then
        icon = ""
      elseif action.kind:match("refactor") then
        icon = ""
      elseif action.kind:match("source") then
        icon = ""
      end
    end

    table.insert(result, {
      display = (icon ~= "" and icon .. " " or "") .. action.title,
      action = action,
    })
  end

  return result
end

return M
