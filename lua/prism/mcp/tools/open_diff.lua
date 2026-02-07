--- prism.nvim MCP Tool: openDiff
--- Opens a diff view for a file, blocking until user accepts or rejects
--- @module prism.mcp.tools.open_diff

local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Active diff sessions
--- @type table<string, table>
local active_diffs = {}

--- Tool definition
M.definition = {
  description = "Open a diff view comparing original and modified content. Blocks until user accepts or rejects the changes.",
  blocking = true,
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Absolute path to the file being diffed",
      },
      originalContent = {
        type = "string",
        description = "Original file content",
      },
      modifiedContent = {
        type = "string",
        description = "Modified file content with proposed changes",
      },
      title = {
        type = "string",
        description = "Title for the diff view",
      },
      language = {
        type = "string",
        description = "Language for syntax highlighting",
      },
    },
    required = { "filePath", "originalContent", "modifiedContent" },
  },
  handler = function(params, call_id)
    local file_path = params.filePath
    local original = params.originalContent
    local modified = params.modifiedContent
    local title = params.title or ("Diff: " .. vim.fn.fnamemodify(file_path, ":t"))
    local language = params.language

    -- Detect language from file extension if not provided
    if not language then
      local ext = vim.fn.fnamemodify(file_path, ":e")
      local ft_map = {
        lua = "lua",
        py = "python",
        js = "javascript",
        ts = "typescript",
        tsx = "typescriptreact",
        jsx = "javascriptreact",
        rs = "rust",
        go = "go",
        rb = "ruby",
        sh = "bash",
        zsh = "zsh",
        vim = "vim",
        md = "markdown",
        json = "json",
        yaml = "yaml",
        yml = "yaml",
        toml = "toml",
      }
      language = ft_map[ext] or ext
    end

    -- Store diff session
    active_diffs[call_id] = {
      file_path = file_path,
      original = original,
      modified = modified,
      title = title,
      language = language,
      buffers = {},
      windows = {},
    }

    -- Schedule UI creation on main thread
    vim.schedule(function()
      local diff_session = active_diffs[call_id]
      if not diff_session then
        return
      end

      -- Create buffers for original and modified content
      local orig_buf = vim.api.nvim_create_buf(false, true)
      local mod_buf = vim.api.nvim_create_buf(false, true)

      -- Set buffer content
      local orig_lines = vim.split(original, "\n", { plain = true })
      local mod_lines = vim.split(modified, "\n", { plain = true })

      vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, orig_lines)
      vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, mod_lines)

      -- Set buffer options
      for _, buf in ipairs({ orig_buf, mod_buf }) do
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].modifiable = false
        if language then
          vim.bo[buf].filetype = language
        end
      end

      vim.api.nvim_buf_set_name(orig_buf, "prism://diff/original/" .. call_id)
      vim.api.nvim_buf_set_name(mod_buf, "prism://diff/modified/" .. call_id)

      -- Create split layout
      vim.cmd("tabnew")
      local tab = vim.api.nvim_get_current_tabpage()

      vim.api.nvim_set_current_buf(orig_buf)
      local orig_win = vim.api.nvim_get_current_win()

      vim.cmd("vsplit")
      vim.api.nvim_set_current_buf(mod_buf)
      local mod_win = vim.api.nvim_get_current_win()

      -- Enable diff mode
      vim.api.nvim_set_current_win(orig_win)
      vim.cmd("diffthis")
      vim.api.nvim_set_current_win(mod_win)
      vim.cmd("diffthis")

      -- Store references
      diff_session.buffers = { orig_buf, mod_buf }
      diff_session.windows = { orig_win, mod_win }
      diff_session.tab = tab

      -- Set up keymaps for accept/reject
      local config = require("prism.config")
      local accept_key = config.get("keymaps.accept_all") or "<leader>cY"
      local reject_key = config.get("keymaps.reject_all") or "<leader>cN"

      local function set_keymap(buf)
        vim.keymap.set("n", accept_key, function()
          M.accept(call_id)
        end, { buffer = buf, desc = "Accept diff changes" })

        vim.keymap.set("n", reject_key, function()
          M.reject(call_id)
        end, { buffer = buf, desc = "Reject diff changes" })

        vim.keymap.set("n", "q", function()
          M.reject(call_id)
        end, { buffer = buf, desc = "Close and reject diff" })
      end

      set_keymap(orig_buf)
      set_keymap(mod_buf)

      -- Set window titles
      vim.wo[orig_win].statusline = "%#DiffDelete# ORIGINAL %* " .. title
      vim.wo[mod_win].statusline = "%#DiffAdd# MODIFIED %* " .. title

      event.emit(event.events.DIFF_CREATED, {
        call_id = call_id,
        file_path = file_path,
      })

      -- Focus modified window
      vim.api.nvim_set_current_win(mod_win)
    end)

    -- Return nil to indicate this is a blocking call
    -- The actual result will be provided via resolve/reject
    return nil
  end,
}

--- Accept the diff changes
--- @param call_id string The call ID of the diff session
function M.accept(call_id)
  local session = active_diffs[call_id]
  if not session then
    util.log.warn("No diff session found for: " .. call_id)
    return
  end

  -- Apply the changes to the actual file
  vim.schedule(function()
    -- Write modified content to file
    local mod_lines = vim.split(session.modified, "\n", { plain = true })
    local ok, err = pcall(function()
      vim.fn.writefile(mod_lines, session.file_path)
    end)

    if not ok then
      util.log.error("Failed to write file: " .. session.file_path, { error = err })
    end

    -- Reload any buffer showing this file
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == session.file_path then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("edit!")
        end)
      end
    end

    -- Close diff tab
    M.close_diff(call_id)

    -- Resolve the blocking call
    local registry = require("prism.mcp.tools")
    registry.resolve(call_id, {
      accepted = true,
      filePath = session.file_path,
    })

    event.emit(event.events.DIFF_ACCEPTED, {
      call_id = call_id,
      file_path = session.file_path,
    })
  end)
end

--- Reject the diff changes
--- @param call_id string The call ID of the diff session
function M.reject(call_id)
  local session = active_diffs[call_id]
  if not session then
    util.log.warn("No diff session found for: " .. call_id)
    return
  end

  vim.schedule(function()
    -- Close diff tab
    M.close_diff(call_id)

    -- Reject the blocking call
    local registry = require("prism.mcp.tools")
    registry.reject(call_id, "Changes rejected by user")

    event.emit(event.events.DIFF_REJECTED, {
      call_id = call_id,
      file_path = session.file_path,
    })
  end)
end

--- Close a diff session
--- @param call_id string The call ID
function M.close_diff(call_id)
  local session = active_diffs[call_id]
  if not session then
    return
  end

  -- Close the tab if it exists
  if session.tab and vim.api.nvim_tabpage_is_valid(session.tab) then
    local tab_nr = vim.api.nvim_tabpage_get_number(session.tab)
    pcall(vim.cmd, "tabclose " .. tab_nr)
  end

  -- Clean up buffers
  for _, buf in ipairs(session.buffers or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  active_diffs[call_id] = nil
end

--- Get all active diff sessions
--- @return table<string, table>
function M.get_active()
  return vim.deepcopy(active_diffs)
end

--- Close all diff sessions
function M.close_all()
  for call_id, _ in pairs(active_diffs) do
    M.close_diff(call_id)
  end
end

--- Register this tool with the registry
--- @param registry table Tool registry
function M.register(registry)
  registry.register("openDiff", M.definition)
end

return M
