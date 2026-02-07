---@module 'prism.ui.timeline'
--- Timeline View - Shows recent Claude edits with undo/goto controls

local M = {}

local config = require("prism.config")

-- State
local state = {
	bufnr = nil,
	winid = nil,
}

--- Format relative time
---@param timestamp number Unix timestamp
---@return string
local function relative_time(timestamp)
	local diff = os.time() - timestamp
	if diff < 60 then
		return string.format("%ds ago", diff)
	elseif diff < 3600 then
		return string.format("%dm ago", math.floor(diff / 60))
	elseif diff < 86400 then
		return string.format("%dh ago", math.floor(diff / 3600))
	else
		return string.format("%dd ago", math.floor(diff / 86400))
	end
end

--- Create timeline content
---@return string[] lines
---@return table[] entries Entry metadata for each line
local function create_content()
	local companion = require("prism.companion")
	local timeline = companion.get_timeline()
	local status = companion.get_status()

	local lines = {}
	local entries = {}

	-- Header
	table.insert(lines, " Prism Edit Timeline")
	table.insert(entries, { type = "header" })

	table.insert(lines, string.format(" Mode: %s | Edits: %d", status.mode, status.edit_count))
	table.insert(entries, { type = "status" })

	table.insert(lines, "")
	table.insert(entries, { type = "spacer" })

	if #timeline == 0 then
		table.insert(lines, " No edits yet")
		table.insert(entries, { type = "empty" })
	else
		-- Column headers
		table.insert(lines, " File                          +/-      Time      Actions")
		table.insert(entries, { type = "header" })

		table.insert(lines, string.rep("─", 60))
		table.insert(entries, { type = "separator" })

		for i, entry in ipairs(timeline) do
			local filename = vim.fn.fnamemodify(entry.file, ":t")
			if #filename > 25 then
				filename = filename:sub(1, 22) .. "..."
			end

			local changes = string.format("+%d -%d", entry.added, entry.removed)
			local time_str = relative_time(entry.timestamp)
			local overlay = entry.has_overlay and "*" or " "

			local line = string.format(
				" %s%-25s  %-8s  %-8s  [u]ndo [Enter]goto",
				overlay,
				filename,
				changes,
				time_str
			)

			table.insert(lines, line)
			table.insert(entries, {
				type = "entry",
				index = i,
				file = entry.file,
				has_overlay = entry.has_overlay,
			})
		end
	end

	table.insert(lines, "")
	table.insert(entries, { type = "spacer" })

	table.insert(lines, " [Y] Accept all  [N] Revert all  [q] Close  [r] Refresh")
	table.insert(entries, { type = "footer" })

	return lines, entries
end

--- Get entry at cursor line
---@return table|nil
local function get_current_entry()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local line = cursor[1]

	local entries = vim.b[state.bufnr].prism_entries
	if entries and entries[line] then
		return entries[line]
	end

	return nil
end

--- Refresh timeline content
function M.refresh()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local lines, entries = create_content()

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
	vim.bo[state.bufnr].modifiable = false

	vim.b[state.bufnr].prism_entries = entries
end

--- Close timeline window
function M.close()
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_close(state.winid, true)
	end
	state.winid = nil
	state.bufnr = nil
end

--- Open timeline window
function M.open()
	-- Close existing
	M.close()

	-- Create buffer
	state.bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[state.bufnr].buftype = "nofile"
	vim.bo[state.bufnr].bufhidden = "wipe"
	vim.bo[state.bufnr].swapfile = false
	vim.bo[state.bufnr].filetype = "prism-timeline"

	-- Calculate window size
	local width = 65
	local height = 15
	local ui_config = config.get("ui") or {}

	local win_width = vim.o.columns
	local win_height = vim.o.lines

	local col = math.floor((win_width - width) / 2)
	local row = math.floor((win_height - height) / 2)

	-- Create floating window
	state.winid = vim.api.nvim_open_win(state.bufnr, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = ui_config.border or "rounded",
		title = " Timeline ",
		title_pos = "center",
	})

	-- Set window options
	vim.wo[state.winid].cursorline = true
	vim.wo[state.winid].wrap = false

	-- Populate content
	M.refresh()

	-- Set up keymaps
	local opts = { buffer = state.bufnr, noremap = true, silent = true }

	-- Close
	vim.keymap.set("n", "q", M.close, opts)
	vim.keymap.set("n", "<Esc>", M.close, opts)

	-- Refresh
	vim.keymap.set("n", "r", M.refresh, opts)

	-- Undo entry
	vim.keymap.set("n", "u", function()
		local entry = get_current_entry()
		if entry and entry.type == "entry" then
			local companion = require("prism.companion")
			companion.revert(entry.file)
			M.refresh()
		end
	end, opts)

	-- Goto entry
	vim.keymap.set("n", "<CR>", function()
		local entry = get_current_entry()
		if entry and entry.type == "entry" then
			M.close()
			vim.cmd("edit " .. vim.fn.fnameescape(entry.file))
		end
	end, opts)

	-- Accept all
	vim.keymap.set("n", "Y", function()
		local companion = require("prism.companion")
		local timeline = companion.get_timeline()
		for _, entry in ipairs(timeline) do
			if entry.has_overlay then
				companion.acknowledge(entry.file)
			end
		end
		vim.notify("All edits acknowledged", vim.log.levels.INFO)
		M.refresh()
	end, opts)

	-- Revert all
	vim.keymap.set("n", "N", function()
		local companion = require("prism.companion")
		local timeline = companion.get_timeline()
		for _, entry in ipairs(timeline) do
			companion.revert(entry.file)
		end
		vim.notify("All edits reverted", vim.log.levels.INFO)
		M.refresh()
	end, opts)

	-- Move cursor to first entry
	for i, entry in ipairs(vim.b[state.bufnr].prism_entries or {}) do
		if entry.type == "entry" then
			vim.api.nvim_win_set_cursor(state.winid, { i, 0 })
			break
		end
	end
end

--- Toggle timeline
function M.toggle()
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		M.close()
	else
		M.open()
	end
end

return M
