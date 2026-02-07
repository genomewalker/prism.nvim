--- prism.nvim MCP Tool: set_style
--- Allows Claude to set working style via natural language
--- Consolidates trust mode + narration settings
--- @module prism.mcp.tools.set_style

local util = require("prism.util")

local M = {}

--- Style presets
local styles = {
	careful = {
		mode = "guardian",
		narrated = true,
		description = "Guardian mode with narration - reviews every edit, explains vim commands",
	},
	trust = {
		mode = "companion",
		narrated = false,
		description = "Companion mode - auto-apply with visual overlay and easy undo",
	},
	fast = {
		mode = "autopilot",
		narrated = false,
		description = "Autopilot mode - fast auto-apply with minimal UI",
	},
	teach = {
		mode = nil, -- don't change trust mode
		narrated = true,
		description = "Enable narration only - explains vim commands as they execute",
	},
	quiet = {
		mode = nil, -- don't change trust mode
		narrated = false,
		description = "Disable narration only - stop explaining vim commands",
	},
}

--- Tool definition
M.definition = {
	description = [[Change how you work with the user - adjusts review level and narration.

Use this when the user says things like:
- "be careful" / "slow down" / "I want to review everything" → careful
- "I trust you" / "go ahead" / "that's fine" → trust
- "full speed" / "autopilot" / "just do it" → fast
- "teach me vim" / "narrated mode" / "explain commands" → teach
- "quiet mode" / "stop explaining" / "no narration" → quiet

Styles:
- careful: Guardian mode + narration (safest, most educational)
- trust: Companion mode, no narration (balanced, recommended)
- fast: Autopilot mode, no narration (fastest, minimal UI)
- teach: Enable narration only (learn vim without changing trust)
- quiet: Disable narration only (stop explanations)]],
	inputSchema = {
		type = "object",
		properties = {
			style = {
				type = "string",
				enum = { "careful", "trust", "fast", "teach", "quiet" },
				description = "The working style to set",
			},
		},
		required = { "style" },
	},
	handler = function(params, _call_id)
		local style_name = params.style
		if not style_name then
			return {
				content = { { type = "text", text = "Error: style is required" } },
				isError = true,
			}
		end

		local style = styles[style_name]
		if not style then
			return {
				content = { { type = "text", text = "Error: unknown style '" .. style_name .. "'" } },
				isError = true,
			}
		end

		local result = {
			success = true,
			style = style_name,
			changes = {},
		}

		-- Set trust mode if specified
		if style.mode then
			vim.schedule(function()
				local ok, companion = pcall(require, "prism.companion")
				if ok then
					local success, err = companion.set_mode(style.mode)
					if success then
						result.changes.mode = style.mode
					else
						result.success = false
						result.error = err or "Failed to set trust mode"
					end
				else
					result.success = false
					result.error = "Companion module not available"
				end
			end)
		end

		-- Set narration via the Python MCP server's config
		-- This is handled by sending a signal that the Python side can read
		result.changes.narrated = style.narrated
		result.narrated = style.narrated
		result.message = style.description

		-- Wait for scheduled operations
		vim.wait(100, function()
			return result.changes.mode or result.error or not style.mode
		end, 10)

		return {
			content = {
				{
					type = "text",
					text = util.json_encode(result),
				},
			},
			isError = not result.success,
		}
	end,
}

--- Register this tool with the registry
--- @param registry table Tool registry
function M.register(registry)
	registry.register("set_style", M.definition)
	-- Alias for camelCase
	registry.register("setStyle", M.definition)
end

return M
