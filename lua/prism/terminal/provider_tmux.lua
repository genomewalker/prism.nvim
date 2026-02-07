---@module 'prism.terminal.provider_tmux'
--- Tmux provider - Run Claude in a tmux pane (clean terminal, no Neovim quirks)

local M = {}

local state = {
	pane_id = nil,
	session = nil,
}

--- Check if tmux is available and we're inside tmux
---@return boolean
function M.is_available()
	return vim.env.TMUX ~= nil
end

--- Get current tmux pane
---@return string|nil
local function get_current_pane()
	local result = vim.fn.system("tmux display-message -p '#{pane_id}'")
	return vim.trim(result)
end

--- Create a new pane for Claude
---@param cmd string Command to run
---@param opts table Options (position, size)
---@return boolean success
function M.open(cmd, opts)
	opts = opts or {}
	local position = opts.position or "right"
	local size = opts.size or 40

	-- Build tmux split command
	local split_cmd
	if position == "right" then
		split_cmd = string.format("tmux split-window -h -l %d%% '%s'", size, cmd)
	elseif position == "left" then
		split_cmd = string.format("tmux split-window -hb -l %d%% '%s'", size, cmd)
	elseif position == "bottom" then
		split_cmd = string.format("tmux split-window -v -l %d%% '%s'", size, cmd)
	elseif position == "top" then
		split_cmd = string.format("tmux split-window -vb -l %d%% '%s'", size, cmd)
	else
		split_cmd = string.format("tmux split-window -h -l %d%% '%s'", size, cmd)
	end

	-- Create the pane
	local result = vim.fn.system(split_cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to create tmux pane: " .. result, vim.log.levels.ERROR)
		return false
	end

	-- Get the new pane ID
	state.pane_id = vim.trim(vim.fn.system("tmux display-message -p '#{pane_id}'"))

	-- Return focus to Neovim pane
	vim.fn.system("tmux last-pane")

	return true
end

--- Close the Claude pane
function M.close()
	if state.pane_id then
		vim.fn.system(string.format("tmux kill-pane -t %s", state.pane_id))
		state.pane_id = nil
	end
end

--- Toggle the Claude pane
---@param cmd string Command to run if opening
---@param opts table Options
function M.toggle(cmd, opts)
	if M.is_visible() then
		M.close()
	else
		M.open(cmd, opts)
	end
end

--- Check if Claude pane is visible
---@return boolean
function M.is_visible()
	if not state.pane_id then
		return false
	end

	-- Check if pane still exists
	local result = vim.fn.system(string.format("tmux list-panes -F '#{pane_id}' | grep -q '%s'", state.pane_id))
	return vim.v.shell_error == 0
end

--- Focus the Claude pane
function M.focus()
	if state.pane_id then
		vim.fn.system(string.format("tmux select-pane -t %s", state.pane_id))
	end
end

--- Send text to Claude pane
---@param text string Text to send
function M.send(text)
	if state.pane_id then
		-- Escape single quotes and send
		local escaped = text:gsub("'", "'\\''")
		vim.fn.system(string.format("tmux send-keys -t %s '%s' Enter", state.pane_id, escaped))
	end
end

--- Send interrupt (Ctrl+C) to Claude pane
function M.interrupt()
	if state.pane_id then
		vim.fn.system(string.format("tmux send-keys -t %s C-c", state.pane_id))
	end
end

--- Get pane ID
---@return string|nil
function M.get_pane_id()
	return state.pane_id
end

return M
