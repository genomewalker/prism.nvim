--- prism.nvim MCP Tool: getOpenEditors
--- Gets information about all open editor tabs/buffers
--- @module prism.mcp.tools.get_editors

local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
  description = "Get information about all open editor tabs and buffers",
  inputSchema = {
    type = "object",
    properties = {
      includeHidden = {
        type = "boolean",
        description = "Include hidden/background buffers",
        default = false,
      },
      includeSpecial = {
        type = "boolean",
        description = "Include special buffers (terminals, quickfix, etc.)",
        default = false,
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    local include_hidden = params.includeHidden or false
    local include_special = params.includeSpecial or false

    local editors = {}
    local active_buf = vim.api.nvim_get_current_buf()
    local active_win = vim.api.nvim_get_current_win()

    -- Get all buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local is_loaded = vim.api.nvim_buf_is_loaded(buf)
      local is_listed = vim.bo[buf].buflisted
      local is_special = util.buf_is_special(buf)

      -- Apply filters
      if not is_loaded then
        goto continue
      end
      if not include_hidden and not is_listed then
        goto continue
      end
      if not include_special and is_special then
        goto continue
      end

      local buf_name = vim.api.nvim_buf_get_name(buf)
      local filetype = vim.bo[buf].filetype
      local modified = vim.bo[buf].modified
      local readonly = vim.bo[buf].readonly

      -- Find windows showing this buffer
      local windows = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          local tab = vim.api.nvim_win_get_tabpage(win)
          table.insert(windows, {
            window = win,
            tabpage = tab,
            isActive = win == active_win,
            isFloating = util.is_floating(win),
          })
        end
      end

      local editor = {
        bufnr = buf,
        filePath = buf_name ~= "" and buf_name or nil,
        fileName = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":t") or "[No Name]",
        relativePath = buf_name ~= "" and util.relative_path(buf_name) or nil,
        language = filetype ~= "" and filetype or nil,
        isModified = modified,
        isReadOnly = readonly,
        isActive = buf == active_buf,
        isSpecial = is_special,
        windows = windows,
        lineCount = vim.api.nvim_buf_line_count(buf),
      }

      -- Get cursor position if this is the active buffer
      if buf == active_buf then
        local cursor = vim.api.nvim_win_get_cursor(active_win)
        editor.cursor = {
          line = cursor[1],
          character = cursor[2] + 1,
        }
      end

      table.insert(editors, editor)

      ::continue::
    end

    -- Sort: active first, then by most recent access
    table.sort(editors, function(a, b)
      if a.isActive ~= b.isActive then
        return a.isActive
      end
      return a.bufnr > b.bufnr -- Higher bufnr = more recently created
    end)

    return {
      content = {
        {
          type = "text",
          text = util.json_encode({
            count = #editors,
            editors = editors,
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
  registry.register("getOpenEditors", M.definition)
end

return M
