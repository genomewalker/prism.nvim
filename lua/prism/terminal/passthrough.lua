---@module 'prism.terminal.passthrough'
--- Passthrough mode - Makes Neovim terminal behave like a real terminal
--- Only Ctrl+\ Ctrl+\ escapes to normal mode. Everything else passes through.

local M = {}

--- Setup passthrough mode for a terminal buffer
---@param bufnr number Buffer number
function M.setup(bufnr)
	-- Clear ALL existing terminal keymaps
	local existing = vim.api.nvim_buf_get_keymap(bufnr, "t")
	for _, map in ipairs(existing) do
		pcall(vim.keymap.del, "t", map.lhs, { buffer = bufnr })
	end

	-- The ONLY way out: Ctrl+\ Ctrl+\
	vim.keymap.set("t", "<C-\\><C-\\>", [[<C-\><C-n>]], {
		buffer = bufnr,
		noremap = true,
		silent = true,
		desc = "Exit to normal mode",
	})

	-- Optional: Ctrl+\ Ctrl+n also works (vim default, but explicit)
	vim.keymap.set("t", "<C-\\><C-n>", [[<C-\><C-n>]], {
		buffer = bufnr,
		noremap = true,
		silent = true,
		desc = "Exit to normal mode",
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
	vim.notify([[
Prism Passthrough Terminal:
  All keys pass through to Claude.

  To exit: Ctrl+\ Ctrl+\ (or Ctrl+\ Ctrl+n)

  Then use normal Neovim commands to navigate.
]], vim.log.levels.INFO)
end

return M
