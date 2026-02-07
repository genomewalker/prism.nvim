---@module 'prism.core'
--- Prism Core - Minimal Claude Code integration for Neovim
--- Philosophy: Claude is source of truth. We just provide ergonomics.
--- Optional: MCP server gives Claude full control of Neovim via natural language.

local M = {}

---============================================================================
--- State
---============================================================================

local state = {
	terminal = {
		bufnr = nil,
		winid = nil,
		jobid = nil,
	},
	changed_files = {}, -- Files Claude has modified this session
	mcp_enabled = false, -- Whether MCP server is running
}

---============================================================================
--- Configuration
---============================================================================

local config = {
	toggle_key = "<C-;>", -- One key to rule them all
	terminal_width = 0.4, -- 40% of screen
	auto_reload = true, -- Reload buffers when files change
	notify = true, -- Show notifications
	mcp = true, -- Enable MCP server (gives Claude control of Neovim)
	claude_args = nil, -- Extra args: "--continue --model opus" or use $CLAUDE_ARGS
	passthrough = true, -- Real terminal: only Ctrl+\\ Ctrl+\\ escapes
}

---============================================================================
--- Terminal
---============================================================================

local function terminal_is_visible()
	return state.terminal.winid and vim.api.nvim_win_is_valid(state.terminal.winid)
end

-- Find and adopt an existing Claude terminal (if prism didn't create it)
local function adopt_existing_terminal()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local buftype = vim.bo[buf].buftype
			local bufname = vim.api.nvim_buf_get_name(buf)
			-- Check if it's a terminal running claude
			if buftype == "terminal" and bufname:match("claude") then
				state.terminal.bufnr = buf
				-- Get the job channel
				local ok, channel = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
				if ok then
					state.terminal.jobid = channel
				end
				-- Find the window showing this buffer
				for _, win in ipairs(vim.api.nvim_list_wins()) do
					if vim.api.nvim_win_get_buf(win) == buf then
						state.terminal.winid = win
						break
					end
				end
				return true
			end
		end
	end
	return false
end

local function terminal_open(args)
	-- If args provided, always start fresh with those args
	local force_new = args and args ~= ""

	if terminal_is_visible() and not force_new then
		vim.api.nvim_set_current_win(state.terminal.winid)
		vim.cmd("startinsert")
		return
	end

	-- Close existing terminal if starting with new args
	if force_new and state.terminal.jobid then
		vim.fn.jobstop(state.terminal.jobid)
		state.terminal.bufnr = nil
		state.terminal.jobid = nil
	end

	-- Create split on the right if no window
	if not terminal_is_visible() then
		vim.cmd("vsplit")
		vim.cmd("wincmd L")
		vim.cmd("enew")
		vim.cmd("vertical resize " .. math.floor(vim.o.columns * config.terminal_width))
		state.terminal.winid = vim.api.nvim_get_current_win()
	end

	-- Reuse existing buffer or create new
	if state.terminal.bufnr and vim.api.nvim_buf_is_valid(state.terminal.bufnr) and not force_new then
		vim.api.nvim_win_set_buf(state.terminal.winid, state.terminal.bufnr)
		vim.cmd("startinsert")
	else
		-- Build command with args priority: passed args > config > env
		local claude_args = args or config.claude_args or os.getenv("CLAUDE_ARGS") or ""
		local claude_cmd = "claude " .. claude_args
		state.terminal.jobid = vim.fn.termopen(claude_cmd, {
			on_exit = function()
				state.terminal.bufnr = nil
				state.terminal.jobid = nil
			end,
		})
		state.terminal.bufnr = vim.api.nvim_get_current_buf()

		-- Clean terminal appearance
		vim.bo[state.terminal.bufnr].buflisted = false
		vim.wo[state.terminal.winid].number = false
		vim.wo[state.terminal.winid].relativenumber = false
		vim.wo[state.terminal.winid].signcolumn = "no"
		vim.wo[state.terminal.winid].winfixwidth = true

		-- Enable passthrough mode for real terminal feel
		if config.passthrough then
			local ok, passthrough = pcall(require, "prism.terminal.passthrough")
			if ok then
				passthrough.setup(state.terminal.bufnr)
			end
		end
	end
end

local function terminal_close()
	if state.terminal.winid and vim.api.nvim_win_is_valid(state.terminal.winid) then
		vim.api.nvim_win_hide(state.terminal.winid)
		state.terminal.winid = nil
	end
end

local function terminal_toggle(args)
	-- If args provided, always open with those args
	if args and args ~= "" then
		terminal_open(args)
	elseif terminal_is_visible() then
		terminal_close()
	else
		terminal_open()
	end
end

local function terminal_send(text)
	-- Try to adopt existing terminal if we don't have one
	if not state.terminal.jobid or not state.terminal.bufnr or not vim.api.nvim_buf_is_valid(state.terminal.bufnr) then
		adopt_existing_terminal()
	end

	-- Check if terminal is now valid
	if state.terminal.jobid and state.terminal.bufnr and vim.api.nvim_buf_is_valid(state.terminal.bufnr) then
		vim.fn.chansend(state.terminal.jobid, text .. "\n")
		-- Make sure terminal is visible
		if not terminal_is_visible() then
			terminal_open()
		end
	else
		-- Need to create terminal first
		terminal_open()
		vim.defer_fn(function()
			if state.terminal.jobid then
				vim.fn.chansend(state.terminal.jobid, text .. "\n")
			end
		end, 200)
	end
end

---============================================================================
--- Buffer Sync (Auto-reload)
---============================================================================

local function setup_auto_reload()
	if not config.auto_reload then
		return
	end

	vim.o.autoread = true

	local group = vim.api.nvim_create_augroup("PrismSync", { clear = true })

	-- Check for file changes on various events
	vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
		group = group,
		callback = function()
			if vim.bo.buftype == "" then
				vim.cmd("silent! checktime")
			end
		end,
	})

	-- Track when files are reloaded (Claude edited them)
	vim.api.nvim_create_autocmd("FileChangedShellPost", {
		group = group,
		callback = function(args)
			local file = vim.api.nvim_buf_get_name(args.buf)
			if file ~= "" then
				state.changed_files[file] = os.time()
				if config.notify then
					local name = vim.fn.fnamemodify(file, ":t")
					vim.notify("Claude edited: " .. name, vim.log.levels.INFO)
				end
			end
		end,
	})
end

---============================================================================
--- Context Sending
---============================================================================

local function get_visual_selection()
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local lines = vim.fn.getline(start_pos[2], end_pos[2])

	if #lines == 0 then
		return nil
	end

	-- Trim to selection
	if #lines == 1 then
		lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
	else
		lines[1] = string.sub(lines[1], start_pos[3])
		lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
	end

	return table.concat(lines, "\n"), start_pos[2], end_pos[2]
end

local function send_context()
	local file = vim.fn.expand("%:.")
	local ft = vim.bo.filetype
	local line = vim.fn.line(".")

	-- Check for visual selection
	local selection, start_line, end_line = get_visual_selection()

	local context
	if selection and #selection > 0 then
		context = string.format("File: %s (lines %d-%d)\n```%s\n%s\n```", file, start_line, end_line, ft, selection)
	else
		-- Send current line with context
		local current_line = vim.api.nvim_get_current_line()
		context = string.format("File: %s:%d\n```%s\n%s\n```", file, line, ft, current_line)
	end

	terminal_send(context)
end

local function send_buffer()
	local file = vim.fn.expand("%:.")
	local ft = vim.bo.filetype
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local content = table.concat(lines, "\n")

	local context = string.format("File: %s\n```%s\n%s\n```", file, ft, content)
	terminal_send(context)

	if config.notify then
		vim.notify("Sent buffer to Claude (" .. #lines .. " lines)", vim.log.levels.INFO)
	end
end

local function send_file_path()
	local file = vim.fn.expand("%:p")
	terminal_send("Open this file: " .. file)
end

local function send_diagnostics()
	local diagnostics = vim.diagnostic.get(0)
	if #diagnostics == 0 then
		vim.notify("No diagnostics in current buffer", vim.log.levels.INFO)
		return
	end

	local file = vim.fn.expand("%:.")
	local lines = { "Diagnostics for " .. file .. ":" }
	for _, d in ipairs(diagnostics) do
		local severity = vim.diagnostic.severity[d.severity] or "?"
		table.insert(lines, string.format("  Line %d: [%s] %s", d.lnum + 1, severity, d.message))
	end

	terminal_send(table.concat(lines, "\n"))
end

local function send_prompt()
	vim.ui.input({ prompt = "Send to Claude: " }, function(input)
		if input and #input > 0 then
			terminal_send(input)
		end
	end)
end

local function show_claude_menu()
	local items = {
		{ label = "Send Selection/Line", action = send_context },
		{ label = "Send Buffer", action = send_buffer },
		{ label = "Send Diagnostics", action = send_diagnostics },
		{ label = "Send File Path", action = send_file_path },
		{ label = "Prompt Claude", action = send_prompt },
		{ label = "Toggle Claude", action = terminal_toggle },
	}

	vim.ui.select(items, {
		prompt = "Claude:",
		format_item = function(item) return item.label end,
	}, function(choice)
		if choice then
			choice.action()
		end
	end)
end

---============================================================================
--- Navigation (Jump to changed files)
---============================================================================

local function get_changed_files()
	local files = {}
	for file, time in pairs(state.changed_files) do
		if vim.fn.filereadable(file) == 1 then
			table.insert(files, { file = file, time = time })
		end
	end
	table.sort(files, function(a, b)
		return a.time > b.time
	end)
	return files
end

local function nav_next_changed()
	local files = get_changed_files()
	if #files == 0 then
		vim.notify("No changed files", vim.log.levels.INFO)
		return
	end

	-- Find current file in list
	local current = vim.fn.expand("%:p")
	local current_idx = 0
	for i, f in ipairs(files) do
		if f.file == current then
			current_idx = i
			break
		end
	end

	-- Go to next (wrap around)
	local next_idx = (current_idx % #files) + 1
	vim.cmd("edit " .. vim.fn.fnameescape(files[next_idx].file))
	vim.notify(string.format("Changed file %d/%d", next_idx, #files), vim.log.levels.INFO)
end

local function nav_list_changed()
	local files = get_changed_files()
	if #files == 0 then
		vim.notify("No changed files", vim.log.levels.INFO)
		return
	end

	vim.ui.select(files, {
		prompt = "Changed files:",
		format_item = function(item)
			local name = vim.fn.fnamemodify(item.file, ":~:.")
			local ago = os.time() - item.time
			local time_str = ago < 60 and (ago .. "s ago") or (math.floor(ago / 60) .. "m ago")
			return string.format("%s (%s)", name, time_str)
		end,
	}, function(choice)
		if choice then
			vim.cmd("edit " .. vim.fn.fnameescape(choice.file))
		end
	end)
end

---============================================================================
--- Keymaps
---============================================================================

local function setup_keymaps()
	-- The ONE toggle key - works in normal and terminal mode
	vim.keymap.set("n", config.toggle_key, terminal_toggle, { desc = "Toggle Claude" })
	vim.keymap.set("t", config.toggle_key, terminal_close, { desc = "Hide Claude" })

	-- Quick access: gC = "go Claude" (capital C to avoid conflict with comment plugins)
	vim.keymap.set({ "n", "v" }, "gC", show_claude_menu, { desc = "Claude menu" })

	-- Also try mouse (may not work in all terminals)
	vim.keymap.set({ "n", "v" }, "<RightMouse>", function()
		-- Delay to let selection complete, then show menu
		vim.defer_fn(show_claude_menu, 50)
	end, { desc = "Claude menu" })

	-- Terminal keymaps depend on passthrough setting
	if config.passthrough then
		-- Passthrough: only escape key, everything else goes to Claude
		-- Ctrl+\\ Ctrl+\\ is set by passthrough.lua on the buffer
	else
		-- Navigation mode: Neovim intercepts these keys
		vim.keymap.set("t", "<C-\\><C-\\>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })
		vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], { desc = "Window left" })
		vim.keymap.set("t", "<C-j>", [[<C-\><C-n><C-w>j]], { desc = "Window down" })
		vim.keymap.set("t", "<C-k>", [[<C-\><C-n><C-w>k]], { desc = "Window up" })
		vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], { desc = "Window right" })
	end

	-- Send to Claude
	vim.keymap.set({ "n", "v" }, "<leader>cs", send_context, { desc = "Send selection/line to Claude" })
	vim.keymap.set("n", "<leader>cb", send_buffer, { desc = "Send buffer to Claude" })
	vim.keymap.set("n", "<leader>cf", send_file_path, { desc = "Send file path to Claude" })
	vim.keymap.set("n", "<leader>cd", send_diagnostics, { desc = "Send diagnostics to Claude" })
	vim.keymap.set("n", "<leader>cp", send_prompt, { desc = "Prompt Claude" })

	-- Navigation
	vim.keymap.set("n", "]g", nav_next_changed, { desc = "Next changed file" })
	vim.keymap.set("n", "<leader>cc", nav_list_changed, { desc = "List changed files" })
end

---============================================================================
--- Commands
---============================================================================

local function setup_commands()
	-- :Claude [args] - toggle or open with flags
	-- Examples: :Claude --continue, :Claude --model opus
	vim.api.nvim_create_user_command("Claude", function(opts)
		terminal_toggle(opts.args)
	end, { nargs = "*", desc = "Toggle Claude (pass flags like --continue)" })

	vim.api.nvim_create_user_command("ClaudeSend", function(opts)
		if opts.args ~= "" then
			terminal_send(opts.args)
		else
			send_context()
		end
	end, { nargs = "?", desc = "Send to Claude" })

	vim.api.nvim_create_user_command("ClaudeNav", nav_list_changed, { desc = "Navigate changed files" })

	vim.api.nvim_create_user_command("ClaudeBuffer", send_buffer, { desc = "Send buffer to Claude" })

	vim.api.nvim_create_user_command("ClaudeDiag", send_diagnostics, { desc = "Send diagnostics to Claude" })

	vim.api.nvim_create_user_command("ClaudeMenu", show_claude_menu, { desc = "Show Claude menu" })

	vim.api.nvim_create_user_command("ClaudeClear", function()
		state.changed_files = {}
		vim.notify("Cleared changed files list", vim.log.levels.INFO)
	end, { desc = "Clear changed files" })
end

---============================================================================
--- Setup
---============================================================================

function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_extend("force", config, opts)

	setup_keymaps()
	setup_commands()
	setup_auto_reload()

	-- Auto-start insert in terminal
	vim.api.nvim_create_autocmd("TermOpen", {
		group = vim.api.nvim_create_augroup("PrismTerm", { clear = true }),
		callback = function()
			vim.cmd("startinsert")
		end,
	})

	-- Start MCP server if enabled (gives Claude control of Neovim)
	if config.mcp then
		vim.defer_fn(function()
			local ok, mcp = pcall(require, "prism.mcp")
			if ok then
				local started, err = mcp.start()
				if started then
					state.mcp_enabled = true
					if config.notify then
						vim.notify("Prism MCP ready - Claude can control Neovim", vim.log.levels.INFO)
					end
				else
					vim.notify("MCP server failed: " .. (err or "unknown"), vim.log.levels.WARN)
				end
			end
		end, 100)
	end
end

---============================================================================
--- Public API
---============================================================================

M.toggle = terminal_toggle
M.open = terminal_open
M.close = terminal_close
M.send = terminal_send
M.send_context = send_context
M.send_buffer = send_buffer
M.send_file = send_file_path
M.send_diagnostics = send_diagnostics
M.prompt = send_prompt
M.nav_next = nav_next_changed
M.nav_list = nav_list_changed
M.get_changed_files = get_changed_files

--- Check if MCP is enabled and running
function M.mcp_status()
	if not state.mcp_enabled then
		return { running = false, reason = "disabled" }
	end
	local ok, mcp = pcall(require, "prism.mcp")
	if ok then
		return mcp.status() or { running = false, reason = "not started" }
	end
	return { running = false, reason = "module not found" }
end

return M
