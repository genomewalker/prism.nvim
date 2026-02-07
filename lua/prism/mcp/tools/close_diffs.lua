--- prism.nvim MCP Tool: closeAllDiffTabs
--- Closes all open diff tabs/views
--- @module prism.mcp.tools.close_diffs

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
  description = "Close all open diff tabs and views created by prism",
  inputSchema = {
    type = "object",
    properties = {
      rejectPending = {
        type = "boolean",
        description = "Reject any pending diff approvals (default: true)",
        default = true,
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    local reject_pending = params.rejectPending ~= false

    local closed_count = 0
    local rejected_count = 0

    -- Close diffs managed by open_diff module
    local ok, open_diff = pcall(require, "prism.mcp.tools.open_diff")
    if ok and open_diff.get_active then
      local active_diffs = open_diff.get_active()

      for call_id, _ in pairs(active_diffs) do
        if reject_pending then
          open_diff.reject(call_id)
          rejected_count = rejected_count + 1
        else
          open_diff.close_diff(call_id)
        end
        closed_count = closed_count + 1
      end
    end

    -- Also close any buffers that look like diff buffers
    local diff_buffers = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        -- Check for prism diff buffer naming pattern
        if name:match("^prism://diff/") then
          table.insert(diff_buffers, buf)
        end
      end
    end

    -- Close any tabs that are in diff mode
    local diff_tabs = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      local wins = vim.api.nvim_tabpage_list_wins(tab)
      local is_diff_tab = true

      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
          local buf = vim.api.nvim_win_get_buf(win)
          if not vim.wo[win].diff then
            -- Check if it's a prism diff buffer
            local name = vim.api.nvim_buf_get_name(buf)
            if not name:match("^prism://diff/") then
              is_diff_tab = false
              break
            end
          end
        end
      end

      if is_diff_tab and #wins > 0 then
        table.insert(diff_tabs, tab)
      end
    end

    -- Close diff tabs (in reverse order to avoid index shifting)
    for i = #diff_tabs, 1, -1 do
      local tab = diff_tabs[i]
      if vim.api.nvim_tabpage_is_valid(tab) then
        local tab_nr = vim.api.nvim_tabpage_get_number(tab)
        pcall(vim.cmd, "tabclose " .. tab_nr)
        closed_count = closed_count + 1
      end
    end

    -- Delete orphaned diff buffers
    for _, buf in ipairs(diff_buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    event.emit("diff:all_closed", {
      closedCount = closed_count,
      rejectedCount = rejected_count,
    })

    return {
      content = {
        {
          type = "text",
          text = util.json_encode({
            success = true,
            closedCount = closed_count,
            rejectedCount = rejected_count,
            message = closed_count > 0 and string.format("Closed %d diff view(s)", closed_count)
              or "No diff views were open",
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
  registry.register("closeAllDiffTabs", M.definition)
end

return M
