--- prism.nvim MCP Tool: close_tab
--- Closes a tab or buffer
--- @module prism.mcp.tools.close_tab

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
  description = "Close a tab or buffer in the editor",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "File path to close (optional, closes current if not specified)",
      },
      bufnr = {
        type = "integer",
        description = "Buffer number to close (alternative to filePath)",
      },
      force = {
        type = "boolean",
        description = "Force close even if buffer has unsaved changes",
        default = false,
      },
      save = {
        type = "boolean",
        description = "Save before closing if modified",
        default = false,
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    local file_path = params.filePath
    local bufnr = params.bufnr
    local force = params.force or false
    local save = params.save or false

    -- Determine target buffer
    local target_buf = nil

    if bufnr then
      if vim.api.nvim_buf_is_valid(bufnr) then
        target_buf = bufnr
      else
        return {
          content = {
            {
              type = "text",
              text = util.json_encode({
                success = false,
                error = "Invalid buffer number: " .. bufnr,
              }),
            },
          },
          isError = true,
        }
      end
    elseif file_path then
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
                success = false,
                error = "File not open: " .. file_path,
              }),
            },
          },
          isError = true,
        }
      end
    else
      target_buf = vim.api.nvim_get_current_buf()
    end

    local buf_name = vim.api.nvim_buf_get_name(target_buf)
    local is_modified = vim.bo[target_buf].modified

    -- Handle modified buffer
    if is_modified and not force then
      if save then
        -- Save first
        local ok, err = pcall(function()
          vim.api.nvim_buf_call(target_buf, function()
            vim.cmd("write")
          end)
        end)
        if not ok then
          return {
            content = {
              {
                type = "text",
                text = util.json_encode({
                  success = false,
                  error = "Failed to save before closing: " .. tostring(err),
                }),
              },
            },
            isError = true,
          }
        end
      else
        return {
          content = {
            {
              type = "text",
              text = util.json_encode({
                success = false,
                error = "Buffer has unsaved changes. Use force=true to discard or save=true to save first.",
                filePath = buf_name ~= "" and buf_name or nil,
              }),
            },
          },
          isError = true,
        }
      end
    end

    -- Close the buffer
    local ok, err = pcall(function()
      -- Use bdelete to close nicely, or bwipeout with force
      if force then
        vim.api.nvim_buf_delete(target_buf, { force = true })
      else
        vim.api.nvim_buf_delete(target_buf, { force = false })
      end
    end)

    if ok then
      event.emit("buffer:closed", {
        bufnr = target_buf,
        path = buf_name ~= "" and buf_name or nil,
      })

      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              success = true,
              closedBuffer = target_buf,
              filePath = buf_name ~= "" and buf_name or nil,
              relativePath = buf_name ~= "" and util.relative_path(buf_name) or nil,
              wasModified = is_modified,
              wasSaved = save and is_modified,
            }),
          },
        },
        isError = false,
      }
    else
      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              success = false,
              error = tostring(err),
            }),
          },
        },
        isError = true,
      }
    end
  end,
}

--- Register this tool with the registry
--- @param registry table Tool registry
function M.register(registry)
  registry.register("close_tab", M.definition)
end

return M
