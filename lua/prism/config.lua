--- prism.nvim configuration module
--- @module prism.config

local M = {}

--- Default configuration schema
--- @type table
local defaults = {
	-- Terminal settings
	terminal = {
		provider = "native", -- "native" | "toggleterm" | "floaterm"
		position = "vertical", -- "vertical" | "horizontal" | "float" | "tab"
		width = 0.4, -- percentage of screen width (for vertical/float)
		height = 0.3, -- percentage of screen height (for horizontal/float)
		cmd = "claude", -- claude CLI command
		auto_start = false, -- auto-start terminal on plugin load
		passthrough = true, -- clean terminal: only Ctrl+\ Ctrl+\ exits
	},

	-- MCP (Model Context Protocol) settings
	mcp = {
		auto_start = true, -- auto-start MCP server
		port_range = { 9100, 9199 }, -- port range for MCP server
	},

	-- Claude CLI flags
	claude = {
		model = nil, -- model override (nil uses claude default)
		continue_session = false, -- --continue flag
		resume = nil, -- --resume <session_id>
		chrome = false, -- --chrome flag for browser integration
		verbose = false, -- --verbose flag
		permission_mode = nil, -- "default" | "accept-edits" | "full-auto" | nil
		dangerously_skip_permissions = false, -- skip permission prompts (use with caution)
		custom_flags = {}, -- additional CLI flags as strings
	},

	-- Selection tracking
	selection = {
		enabled = true, -- track visual selections for context
		debounce_ms = 150, -- debounce selection updates
	},

	-- Diff settings
	diff = {
		inline = true, -- show inline diffs
		layout = "vertical", -- "vertical" | "horizontal"
		auto_close = true, -- auto-close diff view on accept/reject
		signs = {
			add = "+",
			delete = "-",
			change = "~",
		},
	},

	-- Trust settings (how edits are handled)
	trust = {
		mode = "companion", -- "guardian" | "companion" | "autopilot"
		-- guardian: block every edit, require y/n review (safest)
		-- companion: auto-accept with visual overlay + easy undo (recommended)
		-- autopilot: auto-accept, minimal UI (fastest)

		escalation = {
			max_lines_changed = 50, -- edits > N lines trigger guardian review
			max_files_in_batch = 5, -- > N files in 10s triggers review
			delete_threshold = 20, -- deleting > N lines triggers review
			patterns = { "*.lock", "*.env", "Makefile" }, -- always review these
		},

		overlay_timeout = 5000, -- ms before overlays fade (0 = never)
		snapshot_limit = 50, -- max snapshots in ring buffer for undo
	},

	-- UI settings
	ui = {
		border = "rounded", -- "none" | "single" | "double" | "rounded" | "solid" | "shadow"
		icons = {
			claude = "󰚩",
			terminal = "",
			diff = "",
			git = "",
			lsp = "",
			error = "",
			warning = "",
			info = "",
			success = "",
			spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
		},
		width = 0.8, -- default popup width (percentage)
		height = 0.8, -- default popup height (percentage)
		blend = 0, -- transparency (0-100)
	},

	-- Keymaps
	keymaps = {
		toggle = "<leader>cc", -- toggle claude terminal
		chat = "<leader>ct", -- open chat input
		send = "<C-CR>", -- send message (in chat buffer)
		actions = "<leader>ca", -- open actions menu
		diff = "<leader>cd", -- show diff for current file
		model = "<leader>cm", -- switch model
		accept_hunk = "<leader>cy", -- accept diff hunk
		reject_hunk = "<leader>cn", -- reject diff hunk
		accept_all = "<leader>cY", -- accept all hunks
		reject_all = "<leader>cN", -- reject all hunks
		stop = "<leader>cx", -- stop current operation
		history = "<leader>ch", -- show session history
		-- Companion mode
		freeze = "<C-z>", -- freeze Claude, switch to guardian mode
		timeline = "<leader>cl", -- open edit timeline
		acknowledge = "ga", -- dismiss overlay (companion mode)
		revert = "gr", -- undo edit (companion mode)
	},

	-- Feature flags
	features = {
		git = true, -- git integration (context, diffs)
		lsp = true, -- LSP integration (diagnostics, symbols)
		memory = true, -- session memory/history
		cost = true, -- cost tracking display
		session = true, -- session management
		treesitter = true, -- treesitter integration for context
		notifications = true, -- show notifications
	},

	-- Hooks
	hooks = {
		before_send = nil, -- function(message) -> message or nil to cancel
		after_response = nil, -- function(response)
		on_error = nil, -- function(error)
		on_diff = nil, -- function(diff_data)
	},

	-- Debug/development
	debug = false, -- enable debug logging
	log_level = "info", -- "trace" | "debug" | "info" | "warn" | "error"
}

--- Current active configuration
--- @type table
local current_config = nil

--- Deep merge tables
--- @param base table Base table
--- @param override table Override table
--- @return table Merged table
local function deep_merge(base, override)
	local result = vim.deepcopy(base)
	for k, v in pairs(override) do
		if type(v) == "table" and type(result[k]) == "table" then
			result[k] = deep_merge(result[k], v)
		else
			result[k] = v
		end
	end
	return result
end

--- Validate configuration
--- @param config table Configuration to validate
--- @return boolean valid
--- @return string|nil error_message
function M.validate(config)
	local validators = {
		["terminal.provider"] = function(v)
			return vim.tbl_contains({ "native", "toggleterm", "floaterm" }, v),
				"terminal.provider must be 'native', 'toggleterm', or 'floaterm'"
		end,
		["terminal.position"] = function(v)
			return vim.tbl_contains({ "vertical", "horizontal", "float", "tab" }, v),
				"terminal.position must be 'vertical', 'horizontal', 'float', or 'tab'"
		end,
		["terminal.width"] = function(v)
			return type(v) == "number" and v > 0 and v <= 1, "terminal.width must be a number between 0 and 1"
		end,
		["terminal.height"] = function(v)
			return type(v) == "number" and v > 0 and v <= 1, "terminal.height must be a number between 0 and 1"
		end,
		["mcp.port_range"] = function(v)
			return type(v) == "table" and #v == 2 and v[1] < v[2],
				"mcp.port_range must be a table with [min, max] ports"
		end,
		["claude.permission_mode"] = function(v)
			if v == nil then
				return true
			end
			return vim.tbl_contains({ "default", "accept-edits", "full-auto" }, v),
				"claude.permission_mode must be 'default', 'accept-edits', 'full-auto', or nil"
		end,
		["diff.layout"] = function(v)
			return vim.tbl_contains({ "vertical", "horizontal" }, v), "diff.layout must be 'vertical' or 'horizontal'"
		end,
		["ui.border"] = function(v)
			return vim.tbl_contains({ "none", "single", "double", "rounded", "solid", "shadow" }, v)
				or type(v) == "table",
				"ui.border must be a valid border style or table"
		end,
		["log_level"] = function(v)
			return vim.tbl_contains({ "trace", "debug", "info", "warn", "error" }, v),
				"log_level must be 'trace', 'debug', 'info', 'warn', or 'error'"
		end,
		["trust.mode"] = function(v)
			return vim.tbl_contains({ "guardian", "companion", "autopilot" }, v),
				"trust.mode must be 'guardian', 'companion', or 'autopilot'"
		end,
	}

	for path, validator in pairs(validators) do
		local keys = vim.split(path, ".", { plain = true })
		local value = config
		for _, key in ipairs(keys) do
			if type(value) ~= "table" then
				break
			end
			value = value[key]
		end

		if value ~= nil then
			local valid, err = validator(value)
			if not valid then
				return false, err
			end
		end
	end

	return true, nil
end

--- Setup configuration with user options
--- @param opts table|nil User options
--- @return table Final configuration
function M.setup(opts)
	opts = opts or {}

	-- Merge with defaults
	current_config = deep_merge(defaults, opts)

	-- Validate
	local valid, err = M.validate(current_config)
	if not valid then
		vim.notify("[prism.nvim] Configuration error: " .. err, vim.log.levels.ERROR)
	end

	return current_config
end

--- Get current configuration
--- @param path string|nil Dot-separated path to config value (e.g., "terminal.width")
--- @return any Configuration value or full config if no path
function M.get(path)
	if not current_config then
		current_config = vim.deepcopy(defaults)
	end

	if not path then
		return current_config
	end

	local keys = vim.split(path, ".", { plain = true })
	local value = current_config
	for _, key in ipairs(keys) do
		if type(value) ~= "table" then
			return nil
		end
		value = value[key]
	end
	return value
end

--- Get default configuration
--- @return table Default configuration
function M.defaults()
	return vim.deepcopy(defaults)
end

--- Reset configuration to defaults
function M.reset()
	current_config = vim.deepcopy(defaults)
end

return M
