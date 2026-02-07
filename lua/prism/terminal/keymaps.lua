---@module 'prism.terminal.keymaps'
--- Terminal keybindings for Claude Code integration
--- Solves: Escape conflicts, navigation, sending to Claude

local M = {}

--- Setup terminal-specific keymaps
---@param bufnr number Terminal buffer number
function M.setup_terminal_keymaps(bufnr)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	-- ESCAPE HANDLING
	-- Double-Escape to exit terminal mode (single Escape goes to Claude)
	-- This lets you use Escape normally in Claude
	vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], opts)

	-- Single Escape stays in terminal (passes to Claude)
	-- Default behavior, no override needed

	-- NAVIGATION
	-- Ctrl+h/j/k/l to navigate between windows (even from terminal)
	vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], opts)
	vim.keymap.set("t", "<C-j>", [[<C-\><C-n><C-w>j]], opts)
	vim.keymap.set("t", "<C-k>", [[<C-\><C-n><C-w>k]], opts)
	vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], opts)

	-- Alt+arrows also work
	vim.keymap.set("t", "<A-Left>", [[<C-\><C-n><C-w>h]], opts)
	vim.keymap.set("t", "<A-Right>", [[<C-\><C-n><C-w>l]], opts)
	vim.keymap.set("t", "<A-Up>", [[<C-\><C-n><C-w>k]], opts)
	vim.keymap.set("t", "<A-Down>", [[<C-\><C-n><C-w>j]], opts)

	-- QUICK ACTIONS
	-- Ctrl+\ to toggle terminal (same as normal mode)
	vim.keymap.set("t", "<C-\\>", [[<C-\><C-n>:PrismToggle<CR>]], opts)

	-- Ctrl+c sends interrupt to Claude (stop generation)
	-- Default behavior, passes through

	-- SCROLLING (in terminal normal mode, after Esc Esc)
	-- These work automatically in normal mode
end

--- Setup global keymaps for Claude integration
function M.setup_global_keymaps()
	-- TOGGLE TERMINAL
	vim.keymap.set("n", "<C-\\>", "<cmd>PrismToggle<CR>", { desc = "Toggle Claude terminal" })
	vim.keymap.set("n", "<leader>cc", "<cmd>PrismToggle<CR>", { desc = "Toggle Claude terminal" })

	-- SEND TO CLAUDE
	-- Visual mode: send selection
	vim.keymap.set("v", "<leader>cs", function()
		require("prism").send_selection()
	end, { desc = "Send selection to Claude" })

	-- Normal mode: send current line
	vim.keymap.set("n", "<leader>cs", function()
		local line = vim.api.nvim_get_current_line()
		require("prism").send(line)
	end, { desc = "Send line to Claude" })

	-- FOCUS TERMINAL
	vim.keymap.set("n", "<leader>cf", function()
		local terminal = require("prism.terminal")
		terminal.focus()
	end, { desc = "Focus Claude terminal" })

	-- QUICK PROMPTS
	vim.keymap.set("n", "<leader>ce", function()
		-- Send "explain this" with current selection/context
		local file = vim.fn.expand("%:t")
		local line = vim.fn.line(".")
		require("prism").send(string.format("Explain the code at %s:%d", file, line))
	end, { desc = "Ask Claude to explain" })

	vim.keymap.set("n", "<leader>cr", function()
		require("prism").send("Review the code I'm looking at for issues")
	end, { desc = "Ask Claude to review" })

	-- FREEZE (switch to guardian mode)
	vim.keymap.set("n", "<C-z>", function()
		require("prism").freeze()
	end, { desc = "Freeze Claude (guardian mode)" })
end

--- Auto-enter insert mode when entering terminal buffer
function M.setup_auto_insert()
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		pattern = "term://*",
		callback = function()
			vim.cmd("startinsert")
		end,
	})

	-- Also when terminal job starts
	vim.api.nvim_create_autocmd("TermOpen", {
		callback = function()
			vim.cmd("startinsert")
		end,
	})
end

--- Setup all keymaps
function M.setup()
	M.setup_global_keymaps()
	M.setup_auto_insert()

	-- Setup terminal-specific keymaps when terminal opens
	vim.api.nvim_create_autocmd("TermOpen", {
		callback = function(args)
			M.setup_terminal_keymaps(args.buf)
		end,
	})
end

return M
