--- prism.nvim MCP Tool: checkDocumentDirty
--- Checks if a document has unsaved changes
--- @module prism.mcp.tools.check_dirty

local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
  description = "Check if a document has unsaved changes (is dirty)",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "File path to check (optional, checks current buffer if not specified)",
      },
      checkAll = {
        type = "boolean",
        description = "Check all open buffers and return list of dirty files",
        default = false,
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    local file_path = params.filePath
    local check_all = params.checkAll or false

    if check_all then
      -- Return all dirty buffers
      local dirty_files = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
          local path = vim.api.nvim_buf_get_name(buf)
          if path ~= "" then
            table.insert(dirty_files, {
              filePath = path,
              relativePath = util.relative_path(path),
              bufnr = buf,
            })
          else
            table.insert(dirty_files, {
              filePath = nil,
              bufnr = buf,
              name = "[No Name]",
            })
          end
        end
      end

      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              hasDirty = #dirty_files > 0,
              count = #dirty_files,
              files = dirty_files,
            }),
          },
        },
        isError = false,
      }
    end

    -- Check specific file or current buffer
    local target_buf = nil

    if file_path then
      -- Find buffer by path
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == file_path then
          target_buf = buf
          break
        end
      end

      if not target_buf then
        return {
          content = {
            {
              type = "text",
              text = util.json_encode({
                isDirty = false,
                isOpen = false,
                message = "File not currently open in editor",
              }),
            },
          },
          isError = false,
        }
      end
    else
      target_buf = vim.api.nvim_get_current_buf()
      file_path = vim.api.nvim_buf_get_name(target_buf)
    end

    local is_dirty = vim.bo[target_buf].modified
    local is_readonly = vim.bo[target_buf].readonly
    local is_modifiable = vim.bo[target_buf].modifiable

    return {
      content = {
        {
          type = "text",
          text = util.json_encode({
            isDirty = is_dirty,
            isOpen = true,
            filePath = file_path ~= "" and file_path or nil,
            relativePath = file_path ~= "" and util.relative_path(file_path) or nil,
            isReadOnly = is_readonly,
            isModifiable = is_modifiable,
            bufnr = target_buf,
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
  registry.register("checkDocumentDirty", M.definition)
end

return M
