--- prism.nvim LSP integration
--- Get diagnostics and format them for Claude
--- @module prism.lsp

local M = {}

--- Severity level names
local SEVERITY_NAMES = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warning",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

--- Severity icons (configurable)
local severity_icons = {
  [vim.diagnostic.severity.ERROR] = "",
  [vim.diagnostic.severity.WARN] = "",
  [vim.diagnostic.severity.INFO] = "",
  [vim.diagnostic.severity.HINT] = "󰌵",
}

--- Get diagnostics for a buffer
--- @param bufnr number|nil Buffer number (default: current)
--- @param severity number|nil Minimum severity level
--- @return vim.Diagnostic[] diagnostics
function M.get_diagnostics(bufnr, severity)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local opts = {}
  if severity then
    opts.severity = { min = severity }
  end

  return vim.diagnostic.get(bufnr, opts)
end

--- Get diagnostics for a specific line range
--- @param bufnr number|nil Buffer number (default: current)
--- @param start_line number Start line (0-indexed)
--- @param end_line number End line (0-indexed)
--- @return vim.Diagnostic[] diagnostics
function M.get_diagnostics_for_range(bufnr, start_line, end_line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local all_diagnostics = vim.diagnostic.get(bufnr)
  local result = {}

  for _, diagnostic in ipairs(all_diagnostics) do
    if diagnostic.lnum >= start_line and diagnostic.lnum <= end_line then
      table.insert(result, diagnostic)
    end
  end

  return result
end

--- Get diagnostics for current line
--- @param bufnr number|nil Buffer number
--- @param line number|nil Line number (0-indexed, default: cursor line)
--- @return vim.Diagnostic[] diagnostics
function M.get_diagnostics_for_line(bufnr, line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  line = line or (vim.api.nvim_win_get_cursor(0)[1] - 1)

  return M.get_diagnostics_for_range(bufnr, line, line)
end

--- Format a single diagnostic for Claude
--- @param diagnostic vim.Diagnostic The diagnostic to format
--- @param file_path string|nil File path for context
--- @return string formatted
local function format_single(diagnostic, file_path)
  local severity = SEVERITY_NAMES[diagnostic.severity] or "unknown"
  local line = diagnostic.lnum + 1 -- Convert to 1-indexed
  local col = diagnostic.col + 1

  local location
  if file_path then
    location = string.format("%s:%d:%d", file_path, line, col)
  else
    location = string.format("L%d:C%d", line, col)
  end

  local source = diagnostic.source or "unknown"
  local code = diagnostic.code and (" [" .. tostring(diagnostic.code) .. "]") or ""

  return string.format("[%s] %s%s: %s (%s)", severity:upper(), source, code, diagnostic.message, location)
end

--- Format diagnostics for sending to Claude
--- @param diagnostics vim.Diagnostic[] Diagnostics to format
--- @param file_path string|nil File path for context
--- @return string formatted Formatted diagnostic text
function M.format_for_claude(diagnostics, file_path)
  if #diagnostics == 0 then
    return "No diagnostics found."
  end

  -- Sort by severity (errors first) then by line
  table.sort(diagnostics, function(a, b)
    if a.severity ~= b.severity then
      return a.severity < b.severity
    end
    return a.lnum < b.lnum
  end)

  local lines = {}
  table.insert(lines, string.format("Found %d diagnostic(s):", #diagnostics))
  table.insert(lines, "")

  for _, diagnostic in ipairs(diagnostics) do
    table.insert(lines, format_single(diagnostic, file_path))
  end

  return table.concat(lines, "\n")
end

--- Get diagnostic summary for a buffer
--- @param bufnr number|nil Buffer number
--- @return table summary { errors, warnings, info, hints, total }
function M.summary(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local diagnostics = vim.diagnostic.get(bufnr)

  local summary = {
    errors = 0,
    warnings = 0,
    info = 0,
    hints = 0,
    total = #diagnostics,
  }

  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.severity == vim.diagnostic.severity.ERROR then
      summary.errors = summary.errors + 1
    elseif diagnostic.severity == vim.diagnostic.severity.WARN then
      summary.warnings = summary.warnings + 1
    elseif diagnostic.severity == vim.diagnostic.severity.INFO then
      summary.info = summary.info + 1
    elseif diagnostic.severity == vim.diagnostic.severity.HINT then
      summary.hints = summary.hints + 1
    end
  end

  return summary
end

--- Format summary as string
--- @param bufnr number|nil Buffer number
--- @return string formatted
function M.format_summary(bufnr)
  local s = M.summary(bufnr)

  if s.total == 0 then
    return "No issues"
  end

  local parts = {}
  if s.errors > 0 then
    table.insert(parts, s.errors .. " error" .. (s.errors > 1 and "s" or ""))
  end
  if s.warnings > 0 then
    table.insert(parts, s.warnings .. " warning" .. (s.warnings > 1 and "s" or ""))
  end
  if s.info > 0 then
    table.insert(parts, s.info .. " info")
  end
  if s.hints > 0 then
    table.insert(parts, s.hints .. " hint" .. (s.hints > 1 and "s" or ""))
  end

  return table.concat(parts, ", ")
end

--- Get file path for buffer
--- @param bufnr number Buffer number
--- @return string|nil path
local function get_file_path(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path and path ~= "" then
    return path
  end
  return nil
end

--- Get all diagnostics across workspace
--- @param severity number|nil Minimum severity
--- @return table<string, vim.Diagnostic[]> diagnostics_by_file
function M.get_workspace_diagnostics(severity)
  local result = {}
  local opts = {}

  if severity then
    opts.severity = { min = severity }
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local diagnostics = vim.diagnostic.get(bufnr, opts)
      if #diagnostics > 0 then
        local file_path = get_file_path(bufnr) or ("buffer:" .. bufnr)
        result[file_path] = diagnostics
      end
    end
  end

  return result
end

--- Format workspace diagnostics for Claude
--- @param severity number|nil Minimum severity
--- @return string formatted
function M.format_workspace_for_claude(severity)
  local by_file = M.get_workspace_diagnostics(severity)

  if vim.tbl_isempty(by_file) then
    return "No diagnostics found in workspace."
  end

  local lines = {}
  local total = 0

  -- Sort files
  local files = vim.tbl_keys(by_file)
  table.sort(files)

  for _, file in ipairs(files) do
    local diagnostics = by_file[file]
    total = total + #diagnostics

    table.insert(lines, "")
    table.insert(lines, "## " .. file)

    for _, diagnostic in ipairs(diagnostics) do
      table.insert(lines, "  " .. format_single(diagnostic))
    end
  end

  table.insert(lines, 1, string.format("Workspace diagnostics (%d total):", total))

  return table.concat(lines, "\n")
end

--- Set severity icons
--- @param icons table<number, string> Icons by severity
function M.set_icons(icons)
  severity_icons = vim.tbl_extend("force", severity_icons, icons)
end

--- Get icon for severity
--- @param severity number Severity level
--- @return string icon
function M.get_icon(severity)
  return severity_icons[severity] or ""
end

--- Check if buffer has errors
--- @param bufnr number|nil Buffer number
--- @return boolean
function M.has_errors(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local diagnostics = vim.diagnostic.get(bufnr, { severity = vim.diagnostic.severity.ERROR })
  return #diagnostics > 0
end

--- Check if buffer has any diagnostics
--- @param bufnr number|nil Buffer number
--- @return boolean
function M.has_diagnostics(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local diagnostics = vim.diagnostic.get(bufnr)
  return #diagnostics > 0
end

--- Get attached LSP clients for buffer
--- @param bufnr number|nil Buffer number
--- @return vim.lsp.Client[] clients
function M.get_clients(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.lsp.get_clients({ bufnr = bufnr })
end

--- Get LSP client names for buffer
--- @param bufnr number|nil Buffer number
--- @return string[] client_names
function M.get_client_names(bufnr)
  local clients = M.get_clients(bufnr)
  local names = {}
  for _, client in ipairs(clients) do
    table.insert(names, client.name)
  end
  return names
end

return M
