--- prism.nvim MCP Tool: edit_file
--- Edit a file without disrupting window layout
--- Uses buffer operations only - never touches windows
--- @module prism.mcp.tools.edit_file

local util = require("prism.util")

local M = {}

M.definition = {
	description = "Edit a file without disrupting window layout. Loads buffer silently, makes changes, saves.",
	inputSchema = {
		type = "object",
		properties = {
			path = {
				type = "string",
				description = "Path to the file to edit",
			},
			search = {
				type = "string",
				description = "Text to search for (literal or pattern)",
			},
			replace = {
				type = "string",
				description = "Replacement text",
			},
			regex = {
				type = "boolean",
				description = "Treat search as regex (default: false, literal match)",
				default = false,
			},
			line = {
				type = "integer",
				description = "Specific line to edit (1-indexed)",
			},
			new_content = {
				type = "string",
				description = "New content for the line (when using line param)",
			},
		},
		required = { "path" },
	},
	handler = function(params, _call_id)
		local path = params.path

		-- Expand relative paths
		if not path:match("^/") then
			path = vim.fn.getcwd() .. "/" .. path
		end

		-- Check file exists
		if vim.fn.filereadable(path) ~= 1 then
			return {
				content = { { type = "text", text = "File not found: " .. path } },
				isError = true,
			}
		end

		-- Load file into hidden buffer (no window changes!)
		local bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)

		local changes = 0

		if params.search and params.replace then
			-- Search and replace
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

			for i, line in ipairs(lines) do
				local new_line
				if params.regex then
					new_line = line:gsub(params.search, params.replace)
				else
					new_line = line:gsub(vim.pesc(params.search), params.replace)
				end
				if new_line ~= line then
					lines[i] = new_line
					changes = changes + 1
				end
			end

			if changes > 0 then
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
			end
		elseif params.line and params.new_content then
			-- Edit specific line
			local line_idx = params.line - 1
			local line_count = vim.api.nvim_buf_line_count(bufnr)

			if params.line > 0 and params.line <= line_count then
				vim.api.nvim_buf_set_lines(bufnr, line_idx, line_idx + 1, false, { params.new_content })
				changes = 1
			end
		end

		-- Save the buffer (silently, no window needed)
		if changes > 0 then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("silent write")
			end)
		end

		local rel_path = vim.fn.fnamemodify(path, ":~:.")
		return {
			content = {
				{
					type = "text",
					text = changes > 0 and ("Edited " .. rel_path .. ": " .. changes .. " changes")
						or ("No changes made to " .. rel_path),
				},
			},
			isError = false,
		}
	end,
}

function M.register(registry)
	registry.register("edit_file", M.definition)
end

return M
