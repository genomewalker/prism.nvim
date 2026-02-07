---@module 'prism.terminal.simple'
--- Simple terminal setup - inspired by claudecode.nvim and claude-code.nvim
--- One toggle key works everywhere. Auto-reload on file changes.

local M = {}

local state = {
	bufnr = nil,
	winid = nil,
	jobid = nil,
}

--- Toggle key that works in both normal and terminal mode
local TOGGLE_KEY = "<C-;>" -- Ctrl+; (less conflicting than Ctrl+,)

--- Check if terminal is visible
function M.is_visible()
	return state.winid and vim.api.nvim_win_is_valid(state.winid)
end

--- Open terminal
function M.open()
	if M.is_visible() then
		vim.api.nvim_set_current_win(state.winid)
		vim.cmd("startinsert")
		return
	end

	-- Create split on the right
	vim.cmd("vsplit")
	vim.cmd("wincmd L")
	vim.cmd("vertical resize " .. math.floor(vim.o.columns * 0.4))

	state.winid = vim.api.nvim_get_current_win()

	-- Create or reuse buffer
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		vim.cmd("startinsert")
	else
		-- Start Claude
		state.jobid = vim.fn.termopen("claude", {
			on_exit = function()
				state.bufnr = nil
				state.jobid = nil
			end,
		})
		state.bufnr = vim.api.nvim_get_current_buf()

		-- Terminal buffer settings
		vim.bo[state.bufnr].buflisted = false
		vim.wo[state.winid].number = false
		vim.wo[state.winid].relativenumber = false
		vim.wo[state.winid].signcolumn = "no"
		vim.wo[state.winid].winfixwidth = true
	end
end

--- Close terminal (hide, don't kill)
function M.close()
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_hide(state.winid)
		state.winid = nil
	end
end

--- Toggle terminal
function M.toggle()
	if M.is_visible() then
		M.close()
	else
		M.open()
	end
end

--- Focus terminal (or open if not visible)
function M.focus()
	if M.is_visible() then
		vim.api.nvim_set_current_win(state.winid)
		vim.cmd("startinsert")
	else
		M.open()
	end
end

--- Setup auto-reload when files change on disk
local function setup_auto_reload()
	vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
		group = vim.api.nvim_create_augroup("PrismAutoReload", { clear = true }),
		callback = function()
			if vim.bo.buftype == "" then
				vim.cmd("silent! checktime")
			end
		end,
	})

	-- Auto-reload when file changes
	vim.o.autoread = true
end

--- Setup the unified toggle key
local function setup_toggle_key()
	-- Normal mode
	vim.keymap.set("n", TOGGLE_KEY, M.toggle, { desc = "Toggle Claude terminal" })

	-- Terminal mode - same key toggles back
	vim.keymap.set("t", TOGGLE_KEY, function()
		M.close()
	end, { desc = "Hide Claude terminal" })

	-- Also Ctrl+\ for passthrough exit, then toggle works
	vim.keymap.set("t", "<C-\\><C-\\>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })
end

--- Setup navigation from terminal
local function setup_terminal_navigation()
	vim.api.nvim_create_autocmd("TermOpen", {
		group = vim.api.nvim_create_augroup("PrismTermNav", { clear = true }),
		callback = function(args)
			local opts = { buffer = args.buf, noremap = true, silent = true }

			-- Ctrl+h/j/k/l to navigate windows
			vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], opts)
			vim.keymap.set("t", "<C-j>", [[<C-\><C-n><C-w>j]], opts)
			vim.keymap.set("t", "<C-k>", [[<C-\><C-n><C-w>k]], opts)
			vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], opts)
		end,
	})
end

--- Setup everything
function M.setup()
	setup_toggle_key()
	setup_terminal_navigation()
	setup_auto_reload()

	-- Command
	vim.api.nvim_create_user_command("Claude", function()
		M.toggle()
	end, { desc = "Toggle Claude terminal" })
end

return M
