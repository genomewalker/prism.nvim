---@module 'prism.terminal.passthrough'
--- Passthrough mode - Makes Neovim terminal behave like a real terminal
--- Only Ctrl+\ Ctrl+\ escapes to normal mode. Everything else passes through.

local M = {}

--- Execute menu action
local function execute_action(action, term_bufnr)
	if action == "copy" then
		-- Copy selection to system clipboard
		vim.cmd('normal! "+y')
		vim.notify("Copied to clipboard", vim.log.levels.INFO)
	elseif action == "paste" then
		-- Paste from system clipboard into terminal
		local content = vim.fn.getreg("+")
		if content and content ~= "" then
			local jobid = vim.b[term_bufnr].terminal_job_id
			if jobid then
				vim.fn.chansend(jobid, content)
			end
		end
	elseif action == "cut" then
		vim.cmd('normal! "+d')
		vim.notify("Cut to clipboard", vim.log.levels.INFO)
	elseif action == "select_all" then
		-- Select all in terminal buffer
		vim.cmd("normal! ggVG")
	elseif action == "clear" then
		-- Send Ctrl+L to clear screen
		local jobid = vim.b[term_bufnr].terminal_job_id
		if jobid then
			vim.fn.chansend(jobid, "\x0c")
		end
	elseif action == "interrupt" then
		-- Send Ctrl+C
		local jobid = vim.b[term_bufnr].terminal_job_id
		if jobid then
			vim.fn.chansend(jobid, "\x03")
		end
	elseif action == "exit_terminal" then
		vim.cmd("stopinsert")
	end
end

--- Show context menu using vim.ui.select
function M.show_context_menu(term_bufnr)
	local actions = {
		{ label = "Copy", action = "copy" },
		{ label = "Paste", action = "paste" },
		{ label = "Cut", action = "cut" },
		{ label = "Select All", action = "select_all" },
		{ label = "Clear Screen", action = "clear" },
		{ label = "Interrupt (^C)", action = "interrupt" },
		{ label = "Normal Mode", action = "exit_terminal" },
	}

	local labels = {}
	for _, item in ipairs(actions) do
		table.insert(labels, item.label)
	end

	vim.ui.select(labels, { prompt = "Claude Terminal:" }, function(choice)
		if not choice then
			return
		end
		for _, item in ipairs(actions) do
			if item.label == choice then
				execute_action(item.action, term_bufnr)
				break
			end
		end
	end)
end

--- Setup passthrough mode for a terminal buffer
---@param bufnr number Buffer number
function M.setup(bufnr)
	-- Clear ALL existing terminal keymaps
	local existing = vim.api.nvim_buf_get_keymap(bufnr, "t")
	for _, map in ipairs(existing) do
		pcall(vim.keymap.del, "t", map.lhs, { buffer = bufnr })
	end

	-- The ONLY way out: Ctrl+\ Ctrl+\ (sets explicit exit flag)
	vim.keymap.set("t", "<C-\\><C-\\>", function()
		vim.b[bufnr].prism_explicit_exit = true
		vim.cmd("stopinsert")
	end, {
		buffer = bufnr,
		noremap = true,
		silent = true,
		desc = "Exit to normal mode (stay in normal mode)",
	})

	-- Optional: Ctrl+\ Ctrl+n also works (also sets flag)
	vim.keymap.set("t", "<C-\\><C-n>", function()
		vim.b[bufnr].prism_explicit_exit = true
		vim.cmd("stopinsert")
	end, {
		buffer = bufnr,
		noremap = true,
		silent = true,
		desc = "Exit to normal mode (stay in normal mode)",
	})

	-- Pass through EVERYTHING else
	-- These would normally be intercepted by Neovim
	local passthrough_keys = {
		"<Esc>",
		"<C-c>",
		"<C-z>",
		"<C-d>",
		"<C-a>",
		"<C-e>",
		"<C-w>",
		"<C-u>",
		"<C-k>",
		"<C-r>",
		"<C-p>",
		"<C-n>",
		"<Tab>",
		"<S-Tab>",
		"<C-Tab>",
		"<C-h>",
		"<C-j>",
		"<C-l>",
		"<Up>",
		"<Down>",
		"<Left>",
		"<Right>",
	}

	for _, key in ipairs(passthrough_keys) do
		-- Map to send the actual key to the terminal
		vim.keymap.set("t", key, key, {
			buffer = bufnr,
			noremap = true,
			silent = true,
		})
	end

	-- Right-click context menu
	vim.keymap.set("t", "<C-RightMouse>", function()
		vim.cmd("stopinsert")
		vim.schedule(function()
			pcall(M.show_context_menu, bufnr)
		end)
	end, {
		buffer = bufnr,
		noremap = true,
		silent = true,
		nowait = true,
		desc = "Show context menu",
	})

	-- Also map in normal mode for when they've already exited
	vim.keymap.set("n", "<C-RightMouse>", function()
		pcall(M.show_context_menu, bufnr)
	end, {
		buffer = bufnr,
		noremap = true,
		silent = true,
		nowait = true,
		desc = "Show context menu",
	})

	-- Set buffer options for clean terminal
	vim.bo[bufnr].scrollback = 10000

	-- Disable line numbers in terminal
	vim.api.nvim_create_autocmd("TermEnter", {
		buffer = bufnr,
		callback = function()
			vim.wo.number = false
			vim.wo.relativenumber = false
			vim.wo.signcolumn = "no"
		end,
	})

	-- Track explicit exit state - if user presses Ctrl+\ Ctrl+\, respect their choice
	vim.b[bufnr].prism_explicit_exit = false

	-- Mouse click: enter insert mode only if click is IN this buffer's window
	vim.keymap.set("n", "<LeftMouse>", function()
		local mouse = vim.fn.getmousepos()
		if mouse and mouse.winid > 0 then
			local clicked_buf = vim.api.nvim_win_get_buf(mouse.winid)
			-- If click is in a DIFFERENT buffer, let normal behavior happen
			if clicked_buf ~= bufnr then
				-- Switch to the clicked window
				vim.api.nvim_set_current_win(mouse.winid)
				if mouse.line > 0 then
					pcall(vim.api.nvim_win_set_cursor, mouse.winid, { mouse.line, math.max(0, mouse.column - 1) })
				end
				return
			end
			-- Click is in THIS terminal buffer
			if mouse.line > 0 then
				pcall(vim.api.nvim_win_set_cursor, mouse.winid, { mouse.line, mouse.column - 1 })
			end
			if not vim.b[bufnr].prism_explicit_exit then
				vim.cmd("startinsert")
			end
		end
	end, {
		buffer = bufnr,
		noremap = true,
		silent = true,
		desc = "Position cursor and enter insert mode (only in this buffer)",
	})

	-- Override insert mode keys to clear the explicit exit flag
	local insert_keys = {
		{ key = "i", cmd = "startinsert" },
		{ key = "a", cmd = "startinsert!" }, -- append after cursor
		{ key = "A", cmd = "startinsert!" }, -- append at end of line
		{ key = "o", cmd = "startinsert!" }, -- open below (just enters insert)
		{ key = "O", cmd = "startinsert!" }, -- open above (just enters insert)
		{ key = "I", cmd = "startinsert" }, -- insert at beginning
		{ key = "s", cmd = "startinsert" }, -- substitute char
		{ key = "S", cmd = "startinsert" }, -- substitute line
		{ key = "C", cmd = "startinsert!" }, -- change to end of line
	}

	for _, mapping in ipairs(insert_keys) do
		vim.keymap.set("n", mapping.key, function()
			vim.b[bufnr].prism_explicit_exit = false
			vim.cmd(mapping.cmd)
		end, {
			buffer = bufnr,
			noremap = true,
			silent = true,
			desc = "Enter terminal insert mode",
		})
	end

	-- Auto-enter insert mode when focusing buffer (but not after explicit exit)
	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = bufnr,
		callback = function()
			if vim.bo[bufnr].buftype == "terminal" and not vim.b[bufnr].prism_explicit_exit then
				vim.cmd("startinsert")
			end
		end,
	})
end

--- Enable passthrough mode globally for all new terminals
function M.enable_global()
	vim.api.nvim_create_autocmd("TermOpen", {
		group = vim.api.nvim_create_augroup("PrismPassthrough", { clear = true }),
		callback = function(args)
			-- Small delay to ensure buffer is ready
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(args.buf) then
					M.setup(args.buf)
					vim.cmd("startinsert")
				end
			end, 10)
		end,
	})
end

--- Show help for passthrough mode
function M.show_help()
	vim.notify(
		[[
Prism Passthrough Terminal:
  All keys pass through to Claude.

  To exit: Ctrl+\ Ctrl+\ (or Ctrl+\ Ctrl+n)
  Right-click: Context menu (Copy, Paste, etc.)

  Then use normal Neovim commands to navigate.
]],
		vim.log.levels.INFO
	)
end

return M
