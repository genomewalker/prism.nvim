--- prism.nvim MCP Tool: set_trust_mode
--- Allows Claude to change the trust mode via natural language
--- @module prism.mcp.tools.set_trust_mode

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
	description = [[Change how the user wants to review your edits.

Use this when the user says things like:
- "be more careful" / "slow down" / "I want to review everything" → guardian
- "that's fine" / "I trust you" / "go ahead" → companion
- "just do it" / "full speed" / "autopilot" → autopilot

Modes:
- guardian: User reviews every edit before it's applied (safest)
- companion: Edits auto-apply with visual overlay, easy undo (recommended)
- autopilot: Edits auto-apply with minimal UI (fastest)]],
	inputSchema = {
		type = "object",
		properties = {
			mode = {
				type = "string",
				enum = { "guardian", "companion", "autopilot" },
				description = "The trust mode to set",
			},
		},
		required = { "mode" },
	},
	handler = function(params, _call_id)
		local mode = params.mode
		if not mode then
			return {
				content = { { type = "text", text = "Error: mode is required" } },
				isError = true,
			}
		end

		local result = { success = false }

		vim.schedule(function()
			local ok, companion = pcall(require, "prism.companion")
			if ok then
				local success, err = companion.set_mode(mode)
				if success then
					result = {
						success = true,
						mode = mode,
						message = "Trust mode set to " .. mode,
					}
				else
					result = {
						success = false,
						error = err or "Failed to set mode",
					}
				end
			else
				result = {
					success = false,
					error = "Companion module not available",
				}
			end
		end)

		-- Wait for schedule
		vim.wait(100, function()
			return result.success or result.error
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
	registry.register("set_trust_mode", M.definition)
	-- Alias
	registry.register("setTrustMode", M.definition)
end

return M
