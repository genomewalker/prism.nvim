--- prism.nvim MCP Tool: saveDocument
--- Saves a document to disk
--- @module prism.mcp.tools.save_document

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
  description = "Save a document to disk",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "File path to save (optional, saves current buffer if not specified)",
      },
      saveAll = {
        type = "boolean",
        description = "Save all modified buffers",
        default = false,
      },
      force = {
        type = "boolean",
        description = "Force save even if file is readonly",
        default = false,
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    local file_path = params.filePath
    local save_all = params.saveAll or false
    local force = params.force or false

    if save_all then
      -- Save all modified buffers
      local saved = {}
      local failed = {}

      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
          local path = vim.api.nvim_buf_get_name(buf)
          if path ~= "" then
            local ok, err = pcall(function()
              vim.api.nvim_buf_call(buf, function()
                if force then
                  vim.cmd("write!")
                else
                  vim.cmd("write")
                end
              end)
            end)

            if ok then
              table.insert(saved, {
                filePath = path,
                relativePath = util.relative_path(path),
              })
              event.emit("file:saved", { path = path })
            else
              table.insert(failed, {
                filePath = path,
                relativePath = util.relative_path(path),
                error = tostring(err),
              })
            end
          end
        end
      end

      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              success = #failed == 0,
              savedCount = #saved,
              failedCount = #failed,
              saved = saved,
              failed = failed,
            }),
          },
        },
        isError = #failed > 0,
      }
    end

    -- Save specific file or current buffer
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
                success = false,
                error = "File not currently open in editor",
              }),
            },
          },
          isError = true,
        }
      end
    else
      target_buf = vim.api.nvim_get_current_buf()
      file_path = vim.api.nvim_buf_get_name(target_buf)
    end

    -- Check if buffer has a name
    if file_path == "" then
      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              success = false,
              error = "Buffer has no file name",
            }),
          },
        },
        isError = true,
      }
    end

    -- Check if modified
    if not vim.bo[target_buf].modified then
      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              success = true,
              filePath = file_path,
              relativePath = util.relative_path(file_path),
              message = "No changes to save",
              wasModified = false,
            }),
          },
        },
        isError = false,
      }
    end

    -- Save the buffer
    local ok, err = pcall(function()
      vim.api.nvim_buf_call(target_buf, function()
        if force then
          vim.cmd("write!")
        else
          vim.cmd("write")
        end
      end)
    end)

    if ok then
      event.emit("file:saved", { path = file_path })
      return {
        content = {
          {
            type = "text",
            text = util.json_encode({
              success = true,
              filePath = file_path,
              relativePath = util.relative_path(file_path),
              wasModified = true,
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
              filePath = file_path,
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
  registry.register("saveDocument", M.definition)
end

return M
