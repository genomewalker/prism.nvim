--- prism.nvim MCP Tool: openFile
--- Opens a file in the editor at an optional line/column
--- @module prism.mcp.tools.open_file

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
	description = "Open a file in the editor area (left side). Terminal stays focused.",
	inputSchema = {
		type = "object",
		properties = {
			path = {
				type = "string",
				description = "Path to the file to open (absolute or relative to cwd)",
			},
			-- Legacy support
			filePath = {
				type = "string",
				description = "Alias for path",
			},
			line = {
				type = "integer",
				description = "Line number to jump to (1-indexed)",
				minimum = 1,
			},
			column = {
				type = "integer",
				description = "Column number to jump to (1-indexed)",
				minimum = 1,
			},
			keep_focus = {
				type = "boolean",
				description = "Return focus to terminal after opening (default: true)",
				default = true,
			},
		},
	},
	handler = function(params, _call_id)
		local file_path = params.path or params.filePath
		if not file_path then
			return {
				content = { { type = "text", text = "Error: path is required" } },
				isError = true,
			}
		end

		local line = params.line or 1
		local column = params.column or 1
		local keep_focus = params.keep_focus ~= false

		-- Expand relative paths
		if not file_path:match("^/") then
			file_path = vim.fn.getcwd() .. "/" .. file_path
		end

		-- Validate file exists
		if vim.fn.filereadable(file_path) ~= 1 then
			return {
				content = { { type = "text", text = "File not found: " .. file_path } },
				isError = true,
			}
		end

		local result = { success = false }

		-- Schedule on main thread
		vim.schedule(function()
			local current_win = vim.api.nvim_get_current_win()

			-- Find a non-terminal, non-floating window for editing
			local target_win = nil
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				local buf = vim.api.nvim_win_get_buf(win)
				local buftype = vim.bo[buf].buftype
				local win_config = vim.api.nvim_win_get_config(win)
				-- Skip terminals, floating windows, and special buffers
				if buftype ~= "terminal" and win_config.relative == "" then
					target_win = win
					break
				end
			end

			if target_win then
				vim.api.nvim_set_current_win(target_win)
			else
				-- Fallback: create new split if no suitable window
				vim.cmd("vsplit")
			end

			vim.cmd("edit " .. vim.fn.fnameescape(file_path))

			local bufnr = vim.api.nvim_get_current_buf()

			-- Jump to line/column
			pcall(vim.api.nvim_win_set_cursor, 0, { line, column - 1 })
			vim.cmd("normal! zz")

			-- Return focus to original window (terminal) if requested
			if keep_focus and vim.api.nvim_win_is_valid(current_win) then
				vim.api.nvim_set_current_win(current_win)
			end

			event.emit("file:opened", {
				path = file_path,
				line = line,
				column = column,
			})

			result = {
				success = true,
				buffer_id = bufnr,
				path = file_path,
				filetype = vim.bo[bufnr].filetype,
			}
		end)

		-- Small delay to let schedule run
		vim.wait(50, function()
			return result.success
		end, 10)

		return {
			content = {
				{
					type = "text",
					text = util.json_encode(result),
				},
			},
			isError = false,
		}
	end,
}

--- Register this tool with the registry
--- @param registry table Tool registry
function M.register(registry)
	registry.register("openFile", M.definition)
	-- Also register with simpler name
	registry.register("open_file", M.definition)
end

return M
