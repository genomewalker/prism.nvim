--- prism.nvim MCP Tool: getDiagnostics
--- Gets LSP diagnostics for a file or workspace
--- @module prism.mcp.tools.get_diagnostics

local util = require("prism.util")

local M = {}

--- Severity names
local severity_names = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warning",
  [vim.diagnostic.severity.INFO] = "information",
  [vim.diagnostic.severity.HINT] = "hint",
}

--- Tool definition
M.definition = {
  description = "Get LSP diagnostics (errors, warnings, etc.) for a file or the entire workspace",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "File path to get diagnostics for (optional, gets all if not specified)",
      },
      severity = {
        type = "string",
        enum = { "error", "warning", "information", "hint" },
        description = "Filter by minimum severity level",
      },
      limit = {
        type = "integer",
        description = "Maximum number of diagnostics to return",
        default = 100,
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    local file_path = params.filePath
    local min_severity = params.severity
    local limit = params.limit or 100

    -- Map severity string to vim severity
    local severity_filter = nil
    if min_severity then
      local severity_map = {
        error = vim.diagnostic.severity.ERROR,
        warning = vim.diagnostic.severity.WARN,
        information = vim.diagnostic.severity.INFO,
        hint = vim.diagnostic.severity.HINT,
      }
      severity_filter = severity_map[min_severity]
    end

    local diagnostics = {}
    local bufnr = nil

    -- Get buffer for specific file
    if file_path then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == file_path then
          bufnr = buf
          break
        end
      end

      if not bufnr then
        -- File not open, try to get diagnostics anyway
        -- (they might be cached from previous sessions)
        return {
          content = {
            {
              type = "text",
              text = util.json_encode({
                count = 0,
                diagnostics = {},
                message = "File not currently open in editor",
              }),
            },
          },
          isError = false,
        }
      end
    end

    -- Get diagnostics
    local raw_diagnostics = vim.diagnostic.get(bufnr, {
      severity = severity_filter and { min = severity_filter } or nil,
    })

    -- Process diagnostics
    local count = 0
    for _, diag in ipairs(raw_diagnostics) do
      if count >= limit then
        break
      end

      local diag_bufnr = diag.bufnr
      local diag_path = vim.api.nvim_buf_get_name(diag_bufnr)

      -- Skip if we're filtering by file and this doesn't match
      if file_path and diag_path ~= file_path then
        goto continue
      end

      local entry = {
        filePath = diag_path,
        relativePath = util.relative_path(diag_path),
        range = {
          start = {
            line = diag.lnum + 1,
            character = diag.col + 1,
          },
          ["end"] = {
            line = (diag.end_lnum or diag.lnum) + 1,
            character = (diag.end_col or diag.col) + 1,
          },
        },
        message = diag.message,
        severity = severity_names[diag.severity] or "unknown",
        source = diag.source,
        code = diag.code,
      }

      table.insert(diagnostics, entry)
      count = count + 1

      ::continue::
    end

    -- Sort by severity (errors first), then by file and line
    table.sort(diagnostics, function(a, b)
      local sev_order = { error = 1, warning = 2, information = 3, hint = 4 }
      local sev_a = sev_order[a.severity] or 5
      local sev_b = sev_order[b.severity] or 5

      if sev_a ~= sev_b then
        return sev_a < sev_b
      end

      if a.filePath ~= b.filePath then
        return a.filePath < b.filePath
      end

      return a.range.start.line < b.range.start.line
    end)

    -- Count by severity
    local summary = {
      error = 0,
      warning = 0,
      information = 0,
      hint = 0,
    }
    for _, diag in ipairs(diagnostics) do
      summary[diag.severity] = (summary[diag.severity] or 0) + 1
    end

    return {
      content = {
        {
          type = "text",
          text = util.json_encode({
            count = #diagnostics,
            truncated = #raw_diagnostics > limit,
            totalCount = #raw_diagnostics,
            summary = summary,
            diagnostics = diagnostics,
          }),
        },
      },
      isError = false,
    }
  end,
}

--- Register this tool with the registry
--- @param registry table Tool registry
function M.register(registry)
  registry.register("getDiagnostics", M.definition)
end

return M
