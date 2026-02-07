--- prism.nvim test harness
--- Minimal init for running tests with plenary.nvim
--- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/unit"

-- Set up runtime path
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local plugin_path = root

-- Add plugin to rtp
vim.opt.runtimepath:prepend(plugin_path)

-- Find and add plenary.nvim
local plenary_paths = {
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
  -- For local development
  vim.fn.expand("~/projects/plenary.nvim"),
  "../plenary.nvim",
}

local plenary_found = false
for _, path in ipairs(plenary_paths) do
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
    plenary_found = true
    break
  end
end

-- Also check if plenary is already loadable
if not plenary_found then
  local ok = pcall(require, "plenary")
  plenary_found = ok
end

if not plenary_found then
  print("ERROR: plenary.nvim not found!")
  print("Install plenary.nvim or set PLENARY_PATH environment variable")
  vim.cmd("cq")
end

-- Set up test environment
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.undofile = false

-- Disable unnecessary features for faster tests
vim.opt.shadafile = "NONE"
vim.opt.loadplugins = false

-- Set up globals for tests
_G.TEST_MODE = true

-- Helper to reset module state between tests
_G.reset_module = function(name)
  package.loaded[name] = nil
  return require(name)
end

-- Helper to create temporary buffer
_G.create_test_buffer = function(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

-- Helper to clean up buffer
_G.delete_test_buffer = function(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- Wait helper for async tests
_G.wait_for = function(condition, timeout_ms)
  timeout_ms = timeout_ms or 1000
  local start = vim.loop.hrtime() / 1e6

  while not condition() do
    vim.wait(10)
    if (vim.loop.hrtime() / 1e6) - start > timeout_ms then
      error("Timeout waiting for condition")
    end
  end
end

-- Print success message
print("Test harness initialized: " .. plugin_path)
