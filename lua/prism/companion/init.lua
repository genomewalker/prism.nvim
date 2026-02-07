---@module 'prism.companion'
--- Companion Mode - Auto-accept with visual overlays and easy undo
--- The sweet spot between automation and control

local M = {}

local config = require("prism.config")
local event = require("prism.event")
local extmarks = require("prism.diff.extmarks")
local compute = require("prism.diff.compute")

-- State
local state = {
	snapshots = {}, -- Ring buffer: { [file] = { original, proposed, timestamp, undo_seq } }
	snapshot_order = {}, -- Array of file paths in order (for ring buffer eviction)
	edit_count = 0, -- Total edits this session
	pending_overlays = {}, -- Files with active overlays
	frozen = false, -- Guardian mode override
	fade_timers = {}, -- Active fade timers by file
}

-- Highlight groups
local function setup_highlights()
	-- Companion mode overlays (informational, not blocking)
	vim.api.nvim_set_hl(0, "PrismCompanionAdd", { bg = "#1a3d1a", default = true })
	vim.api.nvim_set_hl(0, "PrismCompanionDelete", { bg = "#3d1a1a", default = true })
	vim.api.nvim_set_hl(0, "PrismCompanionChange", { bg = "#3d3a1a", default = true })
	vim.api.nvim_set_hl(0, "PrismCompanionVirt", { fg = "#888888", italic = true, default = true })
end

--- Get trust mode from config
---@return string "guardian" | "companion" | "autopilot"
function M.get_mode()
	if state.frozen then
		return "guardian"
	end
	return config.get("trust.mode") or "companion"
end

--- Check if we're in companion mode (auto-accept with overlays)
---@return boolean
function M.is_companion()
	return M.get_mode() == "companion"
end

--- Check if we're in autopilot mode (auto-accept, minimal UI)
---@return boolean
function M.is_autopilot()
	return M.get_mode() == "autopilot"
end

--- Store a snapshot before an edit is applied
--- Called by the diff hook before allowing an edit
---@param file string File path
---@param original string Original content
---@param proposed string Proposed content after edit
function M.snapshot(file, original, proposed)
	setup_highlights()

	local limit = config.get("trust.snapshot_limit") or 50

	-- Evict oldest if at limit
	if #state.snapshot_order >= limit then
		local oldest = table.remove(state.snapshot_order, 1)
		state.snapshots[oldest] = nil
	end

	-- Get current undo sequence number for this buffer
	local undo_seq = nil
	local bufnr = vim.fn.bufnr(file)
	if bufnr ~= -1 then
		undo_seq = vim.fn.undotree(bufnr).seq_cur
	end

	-- Store snapshot
	state.snapshots[file] = {
		original = original,
		proposed = proposed,
		timestamp = os.time(),
		undo_seq = undo_seq,
	}

	-- Update order (remove if exists, add to end)
	for i, f in ipairs(state.snapshot_order) do
		if f == file then
			table.remove(state.snapshot_order, i)
			break
		end
	end
	table.insert(state.snapshot_order, file)

	state.edit_count = state.edit_count + 1

	-- Emit event
	event.emit("companion:snapshot", {
		file = file,
		edit_count = state.edit_count,
	})
end

--- Called when a buffer is reloaded after Claude's edit
--- Renders the diff overlay
---@param bufnr number Buffer number
function M.on_buffer_reload(bufnr)
	local file = vim.api.nvim_buf_get_name(bufnr)
	local snapshot = state.snapshots[file]

	if not snapshot then
		return
	end

	-- Don't show overlays in autopilot mode
	if M.is_autopilot() then
		return
	end

	-- Compute the diff
	local original_lines = vim.split(snapshot.original, "\n")
	local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local hunks = compute.compute(original_lines, current_lines, file)

	if #hunks == 0 then
		return
	end

	-- Render overlays
	for _, hunk in ipairs(hunks) do
		extmarks.render_hunk(bufnr, hunk)
	end

	state.pending_overlays[file] = {
		bufnr = bufnr,
		hunks = hunks,
		timestamp = os.time(),
	}

	-- Count changes for notification
	local added = 0
	local removed = 0
	for _, hunk in ipairs(hunks) do
		added = added + #hunk.new_lines
		removed = removed + #hunk.old_lines
	end

	-- Notify
	local filename = vim.fn.fnamemodify(file, ":t")
	vim.notify(
		string.format("Claude edited %s (+%d/-%d) [gr to undo]", filename, added, removed),
		vim.log.levels.INFO
	)

	-- Schedule fade
	local timeout = config.get("trust.overlay_timeout") or 5000
	if timeout > 0 then
		M.schedule_fade(file, bufnr, timeout)
	end

	event.emit("companion:edit_applied", {
		file = file,
		added = added,
		removed = removed,
		hunk_count = #hunks,
	})
end

--- Schedule overlay fade
---@param file string File path
---@param bufnr number Buffer number
---@param timeout number Milliseconds
function M.schedule_fade(file, bufnr, timeout)
	-- Cancel existing timer
	if state.fade_timers[file] then
		state.fade_timers[file]:stop()
		state.fade_timers[file]:close()
	end

	local timer = vim.loop.new_timer()
	state.fade_timers[file] = timer

	timer:start(timeout, 0, vim.schedule_wrap(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			extmarks.clear_all(bufnr)
		end
		state.pending_overlays[file] = nil
		state.fade_timers[file] = nil
		timer:close()
	end))
end

--- Acknowledge an edit (dismiss overlay)
--- Called with 'ga' keybinding
---@param file string|nil File path (nil = current buffer)
function M.acknowledge(file)
	file = file or vim.api.nvim_buf_get_name(0)

	local overlay = state.pending_overlays[file]
	if overlay then
		extmarks.clear_all(overlay.bufnr)
		state.pending_overlays[file] = nil

		if state.fade_timers[file] then
			state.fade_timers[file]:stop()
			state.fade_timers[file]:close()
			state.fade_timers[file] = nil
		end

		vim.notify("Edit acknowledged", vim.log.levels.INFO)
		event.emit("companion:acknowledged", { file = file })
	end
end

--- Revert an edit to the pre-edit snapshot
--- Called with 'gr' keybinding
---@param file string|nil File path (nil = current buffer)
function M.revert(file)
	file = file or vim.api.nvim_buf_get_name(0)

	local snapshot = state.snapshots[file]
	if not snapshot then
		vim.notify("No snapshot to revert to", vim.log.levels.WARN)
		return
	end

	local bufnr = vim.fn.bufnr(file)
	if bufnr == -1 then
		vim.notify("Buffer not found", vim.log.levels.ERROR)
		return
	end

	-- Restore original content
	local original_lines = vim.split(snapshot.original, "\n")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original_lines)

	-- Save the file
	vim.api.nvim_buf_call(bufnr, function()
		vim.cmd("silent write")
	end)

	-- Clear overlays
	extmarks.clear_all(bufnr)
	state.pending_overlays[file] = nil

	if state.fade_timers[file] then
		state.fade_timers[file]:stop()
		state.fade_timers[file]:close()
		state.fade_timers[file] = nil
	end

	-- Clear snapshot
	state.snapshots[file] = nil
	for i, f in ipairs(state.snapshot_order) do
		if f == file then
			table.remove(state.snapshot_order, i)
			break
		end
	end

	vim.notify("Reverted to pre-edit state", vim.log.levels.INFO)
	event.emit("companion:reverted", { file = file })
end

--- Freeze Claude (switch to guardian mode temporarily)
function M.freeze()
	state.frozen = true

	-- Interrupt Claude terminal
	local terminal = require("prism.terminal")
	if terminal.interrupt then
		terminal.interrupt()
	end

	vim.notify("Claude frozen - switching to guardian mode", vim.log.levels.WARN)
	event.emit("companion:frozen", {})

	-- Write updated trust config for hook
	M.write_trust_config()
end

--- Unfreeze (return to configured trust mode)
function M.unfreeze()
	state.frozen = false
	vim.notify("Companion mode resumed", vim.log.levels.INFO)
	event.emit("companion:unfrozen", {})
	M.write_trust_config()
end

--- Set trust mode at runtime
--- @param mode string "guardian" | "companion" | "autopilot"
--- @return boolean success
--- @return string|nil error
function M.set_mode(mode)
	local valid_modes = { guardian = true, companion = true, autopilot = true }
	if not valid_modes[mode] then
		return false, "Invalid mode: " .. tostring(mode) .. ". Must be guardian, companion, or autopilot."
	end

	-- Update config at runtime
	local current_config = config.get()
	current_config.trust = current_config.trust or {}
	current_config.trust.mode = mode

	-- Clear frozen state when explicitly setting mode
	state.frozen = false

	-- Notify user with mode-specific message
	local icons = { guardian = "🛡️", companion = "🤝", autopilot = "🚀" }
	local descriptions = {
		guardian = "Manual review required for all edits",
		companion = "Auto-accept with visual overlays",
		autopilot = "Full auto-accept, minimal UI",
	}
	vim.notify(
		string.format("%s Trust mode: %s - %s", icons[mode], mode, descriptions[mode]),
		vim.log.levels.INFO
	)

	event.emit("companion:mode_changed", { mode = mode })
	M.write_trust_config()

	return true, nil
end

--- Get list of available modes
--- @return table modes
function M.get_modes()
	return {
		{ id = "guardian", name = "Guardian", desc = "Manual review for all edits", icon = "🛡️" },
		{ id = "companion", name = "Companion", desc = "Auto-accept with overlays", icon = "🤝" },
		{ id = "autopilot", name = "Autopilot", desc = "Full auto, minimal UI", icon = "🚀" },
	}
end

--- Write trust config to JSON file for Python hook to read
function M.write_trust_config()
	local trust_config = {
		mode = M.get_mode(),
		frozen = state.frozen,
		escalation = config.get("trust.escalation") or {},
	}

	local json = vim.json.encode(trust_config)
	local path = "/tmp/prism-trust-config.json"

	local f = io.open(path, "w")
	if f then
		f:write(json)
		f:close()
	end
end

--- Get current status for statusline
---@return table Status info
function M.get_status()
	return {
		mode = M.get_mode(),
		frozen = state.frozen,
		edit_count = state.edit_count,
		pending_count = vim.tbl_count(state.pending_overlays),
	}
end

--- Get edit timeline (list of recent edits)
---@return table[] Array of {file, timestamp, added, removed}
function M.get_timeline()
	local timeline = {}

	for _, file in ipairs(state.snapshot_order) do
		local snapshot = state.snapshots[file]
		if snapshot then
			-- Compute diff stats
			local original_lines = vim.split(snapshot.original, "\n")
			local proposed_lines = vim.split(snapshot.proposed, "\n")
			local added = math.max(0, #proposed_lines - #original_lines)
			local removed = math.max(0, #original_lines - #proposed_lines)

			table.insert(timeline, {
				file = file,
				timestamp = snapshot.timestamp,
				added = added,
				removed = removed,
				has_overlay = state.pending_overlays[file] ~= nil,
			})
		end
	end

	-- Reverse so newest is first
	local reversed = {}
	for i = #timeline, 1, -1 do
		table.insert(reversed, timeline[i])
	end

	return reversed
end

--- Setup companion mode
function M.setup()
	setup_highlights()

	-- Write initial trust config
	M.write_trust_config()

	-- Set up autocmd to detect buffer reloads
	vim.api.nvim_create_autocmd({ "BufReadPost", "FileChangedShellPost" }, {
		group = vim.api.nvim_create_augroup("PrismCompanion", { clear = true }),
		callback = function(args)
			-- Small delay to let the buffer content settle
			vim.defer_fn(function()
				M.on_buffer_reload(args.buf)
			end, 50)
		end,
	})

	-- Set up keymaps
	local keymaps = config.get("keymaps") or {}

	if keymaps.acknowledge then
		vim.keymap.set("n", keymaps.acknowledge, function()
			M.acknowledge()
		end, { desc = "Prism: Acknowledge edit" })
	end

	if keymaps.revert then
		vim.keymap.set("n", keymaps.revert, function()
			M.revert()
		end, { desc = "Prism: Revert edit" })
	end

	if keymaps.freeze then
		vim.keymap.set("n", keymaps.freeze, function()
			if state.frozen then
				M.unfreeze()
			else
				M.freeze()
			end
		end, { desc = "Prism: Toggle freeze" })
	end
end

return M
