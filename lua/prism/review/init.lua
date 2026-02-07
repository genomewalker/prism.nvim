---@module 'prism.review'
--- Review Session Coordinator
--- Manages the edit review workflow for Claude Code edits

local M = {}

local event = require("prism.event")
local compute = require("prism.diff.compute")
local extmarks = require("prism.diff.extmarks")
local util = require("prism.util")

-- State
local state = {
	active_session = nil, -- Current review session
	file_queue = {}, -- Queue of files to review
	keymaps_active = false,
	terminal_win = nil, -- Remember terminal window
	editor_win = nil, -- Editor window for reviews
}

---@class ReviewSession
---@field id string Unique session ID
---@field file string File path being reviewed
---@field original string Original file content
---@field proposed string Proposed content
---@field hunks table[] List of diff hunks
---@field current_hunk number Index of current hunk (1-indexed)
---@field status "active"|"completed"|"cancelled"
---@field call_id string? MCP call ID for blocking resolution
---@field on_complete function? Callback when review completes

-- Highlight groups for review
local function setup_highlights()
	-- Pending changes (yellow/amber)
	vim.api.nvim_set_hl(0, "PrismReviewPending", { bg = "#3d3200", fg = "#ffcc00" })
	vim.api.nvim_set_hl(0, "PrismReviewPendingSign", { fg = "#ffcc00" })

	-- Accepted (green)
	vim.api.nvim_set_hl(0, "PrismReviewAccepted", { bg = "#1a3d1a" })
	vim.api.nvim_set_hl(0, "PrismReviewAcceptedSign", { fg = "#00ff00" })

	-- Rejected (red)
	vim.api.nvim_set_hl(0, "PrismReviewRejected", { bg = "#3d1a1a" })
	vim.api.nvim_set_hl(0, "PrismReviewRejectedSign", { fg = "#ff0000" })
end

-- Find the terminal window
local function find_terminal_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
		if buftype == "terminal" then
			return win
		end
	end
	return nil
end

-- Find or create an editor window (non-terminal)
local function find_or_create_editor_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
		local bufname = vim.api.nvim_buf_get_name(buf)
		if buftype ~= "terminal" and not bufname:match("^prism://") then
			return win
		end
	end

	-- No suitable window, create one
	local current = vim.api.nvim_get_current_win()
	vim.cmd("topleft vsplit")
	local new_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(current)
	return new_win
end

-- Set up keymaps for review session
local function setup_keymaps(bufnr)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	-- Accept current hunk
	vim.keymap.set("n", "y", function()
		M.accept_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Accept hunk" }))
	vim.keymap.set("n", "<leader>cy", function()
		M.accept_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Accept hunk" }))

	-- Reject current hunk
	vim.keymap.set("n", "n", function()
		M.reject_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Reject hunk" }))
	vim.keymap.set("n", "<leader>cn", function()
		M.reject_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Reject hunk" }))

	-- Accept all
	vim.keymap.set("n", "Y", function()
		M.accept_all()
	end, vim.tbl_extend("force", opts, { desc = "Accept all hunks" }))
	vim.keymap.set("n", "<leader>cY", function()
		M.accept_all()
	end, vim.tbl_extend("force", opts, { desc = "Accept all hunks" }))

	-- Reject all
	vim.keymap.set("n", "N", function()
		M.reject_all()
	end, vim.tbl_extend("force", opts, { desc = "Reject all hunks" }))
	vim.keymap.set("n", "<leader>cN", function()
		M.reject_all()
	end, vim.tbl_extend("force", opts, { desc = "Reject all hunks" }))

	-- Navigation
	vim.keymap.set("n", "]c", function()
		M.next_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Next hunk" }))
	vim.keymap.set("n", "[c", function()
		M.prev_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Previous hunk" }))
	vim.keymap.set("n", "<Tab>", function()
		M.next_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Next hunk" }))
	vim.keymap.set("n", "<S-Tab>", function()
		M.prev_hunk()
	end, vim.tbl_extend("force", opts, { desc = "Previous hunk" }))

	-- Return to terminal
	vim.keymap.set("n", "<Esc>", function()
		if state.terminal_win and vim.api.nvim_win_is_valid(state.terminal_win) then
			vim.api.nvim_set_current_win(state.terminal_win)
			vim.cmd("startinsert")
		end
	end, vim.tbl_extend("force", opts, { desc = "Return to terminal" }))
end

-- Clear keymaps from buffer
local function clear_keymaps(bufnr)
	local keys = {
		"y",
		"n",
		"Y",
		"N",
		"]c",
		"[c",
		"<Tab>",
		"<S-Tab>",
		"<Esc>",
		"<leader>cy",
		"<leader>cn",
		"<leader>cY",
		"<leader>cN",
	}
	for _, key in ipairs(keys) do
		pcall(vim.keymap.del, "n", key, { buffer = bufnr })
	end
end

--- Start a new review session
---@param opts table Options: file, original, proposed, call_id, on_complete
---@return string session_id
function M.start(opts)
	setup_highlights()

	local session_id = util.uuid_v4()

	-- Remember terminal window
	state.terminal_win = find_terminal_window()

	-- Protect terminal from resizing
	if state.terminal_win then
		vim.api.nvim_set_option_value("winfixwidth", true, { win = state.terminal_win })
	end
	vim.o.equalalways = false

	-- Find/create editor window
	state.editor_win = find_or_create_editor_window()

	-- Open the file in editor window
	vim.api.nvim_set_current_win(state.editor_win)
	vim.cmd("edit " .. vim.fn.fnameescape(opts.file))
	local bufnr = vim.api.nvim_get_current_buf()

	-- Store original content for revert
	vim.b[bufnr].prism_original = opts.original
	vim.b[bufnr].prism_session_id = session_id

	-- Apply proposed changes to buffer (don't save)
	local proposed_lines = vim.split(opts.proposed, "\n")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, proposed_lines)

	-- Compute diff hunks
	local original_lines = vim.split(opts.original, "\n")
	local hunks = compute.compute(original_lines, proposed_lines, opts.file)

	-- Render hunks with extmarks
	for _, hunk in ipairs(hunks) do
		extmarks.render_hunk(bufnr, hunk)
	end

	-- Create session
	local session = {
		id = session_id,
		file = opts.file,
		bufnr = bufnr,
		original = opts.original,
		proposed = opts.proposed,
		hunks = hunks,
		current_hunk = 1,
		status = "active",
		call_id = opts.call_id,
		on_complete = opts.on_complete,
	}

	state.active_session = session

	-- Set up keymaps
	setup_keymaps(bufnr)

	-- Jump to first hunk
	if #hunks > 0 then
		vim.api.nvim_win_set_cursor(state.editor_win, { hunks[1].start_line, 0 })
	end

	-- Return focus to terminal
	if state.terminal_win and vim.api.nvim_win_is_valid(state.terminal_win) then
		vim.api.nvim_set_current_win(state.terminal_win)
	end

	-- Notify
	local hunk_count = #hunks
	vim.notify(
		string.format(
			"Review: %d change%s in %s | [y]accept [n]reject [Tab]next",
			hunk_count,
			hunk_count == 1 and "" or "s",
			vim.fn.fnamemodify(opts.file, ":t")
		),
		vim.log.levels.INFO
	)

	-- Emit event
	event.emit("review:started", {
		session_id = session_id,
		file = opts.file,
		hunk_count = hunk_count,
	})

	return session_id
end

--- Get current session status
---@return table|nil
function M.get_status()
	if not state.active_session then
		return nil
	end

	local s = state.active_session
	local pending = 0
	local accepted = 0
	local rejected = 0

	for _, hunk in ipairs(s.hunks) do
		if hunk.status == "pending" then
			pending = pending + 1
		elseif hunk.status == "accepted" then
			accepted = accepted + 1
		elseif hunk.status == "rejected" then
			rejected = rejected + 1
		end
	end

	return {
		session_id = s.id,
		file = s.file,
		current_hunk = s.current_hunk,
		total_hunks = #s.hunks,
		pending = pending,
		accepted = accepted,
		rejected = rejected,
	}
end

--- Accept the current hunk
function M.accept_hunk()
	local s = state.active_session
	if not s then
		return
	end

	local hunk = s.hunks[s.current_hunk]
	if not hunk or hunk.status ~= "pending" then
		M.next_hunk()
		return
	end

	-- Mark as accepted
	hunk.status = "accepted"
	extmarks.update_hunk_state(s.bufnr, hunk, "accepted")

	vim.notify(string.format("Accepted hunk %d/%d", s.current_hunk, #s.hunks), vim.log.levels.INFO)

	event.emit("review:hunk:accepted", {
		session_id = s.id,
		hunk_index = s.current_hunk,
	})

	-- Move to next pending hunk or complete
	M.next_hunk()
	M.check_complete()
end

--- Reject the current hunk (revert to original)
function M.reject_hunk()
	local s = state.active_session
	if not s then
		return
	end

	local hunk = s.hunks[s.current_hunk]
	if not hunk or hunk.status ~= "pending" then
		M.next_hunk()
		return
	end

	-- Revert this hunk to original content
	local current_lines = vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false)
	local original_lines = vim.split(s.original, "\n")

	-- Replace the hunk's lines with original
	local start_line = hunk.start_line - 1 -- 0-indexed
	local end_line = hunk.end_line
	local old_lines = hunk.old_lines or {}

	-- Account for line offset from previous rejections
	-- (simplified: just use the old_lines from the hunk)
	if #old_lines > 0 then
		vim.api.nvim_buf_set_lines(s.bufnr, start_line, end_line, false, old_lines)
	end

	-- Mark as rejected
	hunk.status = "rejected"
	extmarks.update_hunk_state(s.bufnr, hunk, "rejected")

	vim.notify(string.format("Rejected hunk %d/%d", s.current_hunk, #s.hunks), vim.log.levels.INFO)

	event.emit("review:hunk:rejected", {
		session_id = s.id,
		hunk_index = s.current_hunk,
	})

	-- Move to next pending hunk or complete
	M.next_hunk()
	M.check_complete()
end

--- Accept all pending hunks
function M.accept_all()
	local s = state.active_session
	if not s then
		return
	end

	for i, hunk in ipairs(s.hunks) do
		if hunk.status == "pending" then
			hunk.status = "accepted"
			extmarks.update_hunk_state(s.bufnr, hunk, "accepted")
		end
	end

	vim.notify("Accepted all hunks", vim.log.levels.INFO)

	event.emit("review:all:accepted", { session_id = s.id })

	M.check_complete()
end

--- Reject all pending hunks
function M.reject_all()
	local s = state.active_session
	if not s then
		return
	end

	-- Revert entire buffer to original
	local original_lines = vim.split(s.original, "\n")
	vim.api.nvim_buf_set_lines(s.bufnr, 0, -1, false, original_lines)

	for i, hunk in ipairs(s.hunks) do
		if hunk.status == "pending" then
			hunk.status = "rejected"
		end
	end

	-- Clear all extmarks
	extmarks.clear_all(s.bufnr)

	vim.notify("Rejected all hunks - reverted to original", vim.log.levels.INFO)

	event.emit("review:all:rejected", { session_id = s.id })

	M.check_complete()
end

--- Navigate to next pending hunk
function M.next_hunk()
	local s = state.active_session
	if not s then
		return
	end

	-- Find next pending hunk
	for i = s.current_hunk + 1, #s.hunks do
		if s.hunks[i].status == "pending" then
			s.current_hunk = i
			local hunk = s.hunks[i]
			if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
				vim.api.nvim_win_set_cursor(state.editor_win, { hunk.start_line, 0 })
			end
			return
		end
	end

	-- Wrap around
	for i = 1, s.current_hunk do
		if s.hunks[i].status == "pending" then
			s.current_hunk = i
			local hunk = s.hunks[i]
			if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
				vim.api.nvim_win_set_cursor(state.editor_win, { hunk.start_line, 0 })
			end
			return
		end
	end
end

--- Navigate to previous pending hunk
function M.prev_hunk()
	local s = state.active_session
	if not s then
		return
	end

	-- Find previous pending hunk
	for i = s.current_hunk - 1, 1, -1 do
		if s.hunks[i].status == "pending" then
			s.current_hunk = i
			local hunk = s.hunks[i]
			if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
				vim.api.nvim_win_set_cursor(state.editor_win, { hunk.start_line, 0 })
			end
			return
		end
	end

	-- Wrap around
	for i = #s.hunks, s.current_hunk, -1 do
		if s.hunks[i].status == "pending" then
			s.current_hunk = i
			local hunk = s.hunks[i]
			if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
				vim.api.nvim_win_set_cursor(state.editor_win, { hunk.start_line, 0 })
			end
			return
		end
	end
end

--- Check if review is complete
function M.check_complete()
	local s = state.active_session
	if not s then
		return
	end

	-- Check if all hunks are resolved
	for _, hunk in ipairs(s.hunks) do
		if hunk.status == "pending" then
			return -- Still have pending hunks
		end
	end

	-- All hunks resolved - complete the review
	M.complete()
end

--- Complete the review session
function M.complete()
	local s = state.active_session
	if not s then
		return
	end

	-- Save the buffer
	vim.api.nvim_buf_call(s.bufnr, function()
		vim.cmd("write")
	end)

	-- Get final content
	local final_lines = vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false)
	local final_content = table.concat(final_lines, "\n")

	-- Clear extmarks and keymaps
	extmarks.clear_all(s.bufnr)
	clear_keymaps(s.bufnr)

	-- Clean up buffer variables
	vim.b[s.bufnr].prism_original = nil
	vim.b[s.bufnr].prism_session_id = nil

	-- Mark session complete
	s.status = "completed"

	-- Count accepted/rejected
	local accepted = 0
	local rejected = 0
	for _, hunk in ipairs(s.hunks) do
		if hunk.status == "accepted" then
			accepted = accepted + 1
		else
			rejected = rejected + 1
		end
	end

	vim.notify(string.format("Review complete: %d accepted, %d rejected", accepted, rejected), vim.log.levels.INFO)

	-- Emit event
	event.emit("review:completed", {
		session_id = s.id,
		file = s.file,
		accepted = accepted,
		rejected = rejected,
		final_content = final_content,
	})

	-- Call completion callback
	if s.on_complete then
		s.on_complete({
			accepted = accepted > 0,
			content = final_content,
		})
	end

	-- Resolve MCP call if blocking
	if s.call_id then
		local tools = require("prism.mcp.tools")
		if tools.resolve then
			tools.resolve(s.call_id, {
				accepted = accepted > 0,
				content = final_content,
				accepted_count = accepted,
				rejected_count = rejected,
			})
		end
	end

	-- Clear session
	state.active_session = nil

	-- Return focus to terminal
	if state.terminal_win and vim.api.nvim_win_is_valid(state.terminal_win) then
		vim.api.nvim_set_current_win(state.terminal_win)
		vim.cmd("startinsert")
	end
end

--- Cancel the review session
function M.cancel()
	local s = state.active_session
	if not s then
		return
	end

	-- Revert to original
	local original_lines = vim.split(s.original, "\n")
	vim.api.nvim_buf_set_lines(s.bufnr, 0, -1, false, original_lines)
	vim.api.nvim_buf_call(s.bufnr, function()
		vim.cmd("write")
	end)

	-- Clear extmarks and keymaps
	extmarks.clear_all(s.bufnr)
	clear_keymaps(s.bufnr)

	-- Clean up
	vim.b[s.bufnr].prism_original = nil
	vim.b[s.bufnr].prism_session_id = nil

	s.status = "cancelled"

	vim.notify("Review cancelled - reverted to original", vim.log.levels.WARN)

	event.emit("review:cancelled", { session_id = s.id })

	-- Reject MCP call if blocking
	if s.call_id then
		local tools = require("prism.mcp.tools")
		if tools.reject then
			tools.reject(s.call_id, "Review cancelled by user")
		end
	end

	state.active_session = nil

	-- Return focus to terminal
	if state.terminal_win and vim.api.nvim_win_is_valid(state.terminal_win) then
		vim.api.nvim_set_current_win(state.terminal_win)
		vim.cmd("startinsert")
	end
end

--- Check if a review is active
---@return boolean
function M.is_active()
	return state.active_session ~= nil
end

--- Get the active session
---@return ReviewSession|nil
function M.get_session()
	return state.active_session
end

return M
