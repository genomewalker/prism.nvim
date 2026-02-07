--- prism.nvim tree explorer integrations
--- Integrates with nvim-tree, neo-tree, oil.nvim
--- @module prism.integrations

local util = require("prism.util")
local event = require("prism.event")

local M = {}

--- Detected tree explorer
--- @type string|nil
local detected_explorer = nil

--- Explorer detection functions
local explorers = {
  ["nvim-tree"] = {
    detect = function()
      return pcall(require, "nvim-tree")
    end,
    get_selection = function()
      local ok, api = pcall(require, "nvim-tree.api")
      if not ok then
        return nil
      end

      local node = api.tree.get_node_under_cursor()
      if not node then
        return nil
      end

      return {
        path = node.absolute_path,
        name = node.name,
        type = node.type, -- "file" or "directory"
        is_directory = node.type == "directory",
      }
    end,
    filetypes = { "NvimTree" },
  },

  ["neo-tree"] = {
    detect = function()
      return pcall(require, "neo-tree")
    end,
    get_selection = function()
      local ok, manager = pcall(require, "neo-tree.sources.manager")
      if not ok then
        return nil
      end

      local state = manager.get_state("filesystem")
      if not state then
        return nil
      end

      local node = state.tree:get_node()
      if not node then
        return nil
      end

      return {
        path = node.path or node:get_id(),
        name = node.name,
        type = node.type,
        is_directory = node.type == "directory",
      }
    end,
    filetypes = { "neo-tree" },
  },

  ["oil"] = {
    detect = function()
      return pcall(require, "oil")
    end,
    get_selection = function()
      local ok, oil = pcall(require, "oil")
      if not ok then
        return nil
      end

      local entry = oil.get_cursor_entry()
      if not entry then
        return nil
      end

      local dir = oil.get_current_dir()
      if not dir then
        return nil
      end

      local path = dir .. entry.name
      if entry.type == "directory" then
        path = path .. "/"
      end

      return {
        path = path,
        name = entry.name,
        type = entry.type,
        is_directory = entry.type == "directory",
      }
    end,
    filetypes = { "oil" },
  },

  ["mini.files"] = {
    detect = function()
      return pcall(require, "mini.files")
    end,
    get_selection = function()
      local ok, files = pcall(require, "mini.files")
      if not ok then
        return nil
      end

      local entry = files.get_fs_entry()
      if not entry then
        return nil
      end

      return {
        path = entry.path,
        name = entry.name,
        type = entry.fs_type,
        is_directory = entry.fs_type == "directory",
      }
    end,
    filetypes = { "minifiles" },
  },
}

--- Detect which tree explorer is available
--- @return string|nil Explorer name
local function detect_explorer()
  for name, explorer in pairs(explorers) do
    local ok = explorer.detect()
    if ok then
      return name
    end
  end
  return nil
end

--- Get selection from the current tree explorer
--- @return table|nil Selection info { path, name, type, is_directory }
function M.get_tree_selection()
  -- Detect explorer if not already done
  if not detected_explorer then
    detected_explorer = detect_explorer()
  end

  if not detected_explorer then
    return nil
  end

  local explorer = explorers[detected_explorer]
  if not explorer then
    return nil
  end

  return explorer.get_selection()
end

--- Check if current buffer is a tree explorer
--- @return boolean
function M.is_tree_buffer()
  local ft = vim.bo.filetype

  for _, explorer in pairs(explorers) do
    if vim.tbl_contains(explorer.filetypes or {}, ft) then
      return true
    end
  end

  return false
end

--- Get the detected explorer name
--- @return string|nil
function M.get_explorer()
  if not detected_explorer then
    detected_explorer = detect_explorer()
  end
  return detected_explorer
end

--- Setup keymaps for tree buffers
local function setup_tree_keymaps()
  local config = require("prism.config")

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("PrismTreeIntegration", { clear = true }),
    pattern = { "NvimTree", "neo-tree", "oil", "minifiles" },
    callback = function(ev)
      local buf = ev.buf

      -- Send file to Claude
      vim.keymap.set("n", "<leader>cs", function()
        local selection = M.get_tree_selection()
        if not selection then
          vim.notify("No file selected", vim.log.levels.WARN)
          return
        end

        if selection.is_directory then
          vim.notify("Cannot send directory", vim.log.levels.WARN)
          return
        end

        -- Read file and send
        local lines = vim.fn.readfile(selection.path)
        if #lines == 0 then
          vim.notify("File is empty", vim.log.levels.WARN)
          return
        end

        local ext = vim.fn.fnamemodify(selection.path, ":e")
        local content = string.format(
          "File: %s\n```%s\n%s\n```",
          util.relative_path(selection.path),
          ext,
          table.concat(lines, "\n")
        )

        local prism = require("prism")
        prism.send(content)
      end, { buffer = buf, desc = "[Prism] Send file to Claude" })

      -- Open file and start chat about it
      vim.keymap.set("n", "<leader>cc", function()
        local selection = M.get_tree_selection()
        if not selection then
          vim.notify("No file selected", vim.log.levels.WARN)
          return
        end

        if selection.is_directory then
          vim.notify("Cannot chat about directory", vim.log.levels.WARN)
          return
        end

        -- Open file in editor
        vim.cmd("edit " .. vim.fn.fnameescape(selection.path))

        -- Open prism chat
        local prism = require("prism")
        prism.chat("About " .. selection.name .. ": ")
      end, { buffer = buf, desc = "[Prism] Open file and chat" })

      -- Ask about directory structure
      vim.keymap.set("n", "<leader>cd", function()
        local selection = M.get_tree_selection()
        local path = selection and selection.path or vim.fn.getcwd()

        if selection and not selection.is_directory then
          path = vim.fn.fnamemodify(selection.path, ":h")
        end

        -- Get directory listing
        local cmd = string.format("find %s -maxdepth 2 -type f | head -50", vim.fn.shellescape(path))
        local files = vim.fn.systemlist(cmd)

        local content = string.format("Directory structure of %s:\n%s", util.relative_path(path), table.concat(files, "\n"))

        local prism = require("prism")
        prism.send(content)
      end, { buffer = buf, desc = "[Prism] Send directory structure" })
    end,
  })
end

--- Setup the integrations module
function M.setup()
  -- Detect available explorer
  detected_explorer = detect_explorer()

  if detected_explorer then
    util.log.debug("Detected tree explorer: " .. detected_explorer)
  end

  -- Setup keymaps
  setup_tree_keymaps()

  event.emit("integrations:ready", {
    explorer = detected_explorer,
  })
end

--- List available integrations
--- @return table Available integrations and their status
function M.list()
  local result = {}

  for name, explorer in pairs(explorers) do
    local ok = explorer.detect()
    result[name] = {
      available = ok,
      filetypes = explorer.filetypes,
    }
  end

  return result
end

return M
