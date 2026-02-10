--- prism.nvim native terminal provider
--- Uses vim.fn.termopen for terminal management (fallback provider)
--- @module prism.terminal.provider_native

local M = {}

--- Terminal state
--- @type table
local state = {
  bufnr = nil,
  winid = nil,
  job_id = nil,
  channel = nil,
  resize_timer = nil,
  autocmd_group = nil,
}

--- Check if native terminal is available (always true)
--- @return boolean
function M.is_available()
  return true
end

--- Force resize to send SIGWINCH to terminal
--- @return boolean success
local function trigger_resize()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    local w = vim.api.nvim_win_get_width(state.winid)
    vim.api.nvim_win_set_width(state.winid, w + 1)
    vim.api.nvim_win_set_width(state.winid, w)
    return true
  end
  return false
end

--- Setup autocmds for the terminal buffer
local function setup_autocmds()
  if state.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.autocmd_group)
  end

  state.autocmd_group = vim.api.nvim_create_augroup("PrismTerminal", { clear = true })

  -- Resize on VimResized (external window size changes)
  vim.api.nvim_create_autocmd("VimResized", {
    group = state.autocmd_group,
    callback = function()
      vim.defer_fn(trigger_resize, 50)
    end,
  })

  -- Resize when entering terminal (catches cc-status that appeared while away)
  vim.api.nvim_create_autocmd("TermEnter", {
    group = state.autocmd_group,
    buffer = state.bufnr,
    callback = function()
      trigger_resize()
    end,
  })

  -- Also trigger on BufEnter for the terminal buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = state.autocmd_group,
    buffer = state.bufnr,
    callback = function()
      trigger_resize()
    end,
  })
end

--- Start continuous resize monitoring for initial stabilization
--- Runs resize every 500ms for 10 seconds to catch cc-status appearance
local function start_resize_monitor()
  -- Cancel existing timer
  if state.resize_timer then
    pcall(vim.fn.timer_stop, state.resize_timer)
    state.resize_timer = nil
  end

  local count = 0
  local max_count = 20  -- 20 * 500ms = 10 seconds

  state.resize_timer = vim.fn.timer_start(500, function()
    count = count + 1
    trigger_resize()

    if count >= max_count then
      if state.resize_timer then
        vim.fn.timer_stop(state.resize_timer)
        state.resize_timer = nil
      end
    end
  end, { ["repeat"] = max_count })
end

--- Create terminal window based on position
--- @param position string Position type
--- @param opts table Options
--- @return number winid
local function create_window(position, opts)
  local width = opts.width or 0.4
  local height = opts.height or 0.3

  if position == "float" then
    -- Calculate floating window dimensions
    local ui = vim.api.nvim_list_uis()[1]
    local float_width = math.floor(ui.width * width)
    local float_height = math.floor(ui.height * height)
    local row = math.floor((ui.height - float_height) / 2)
    local col = math.floor((ui.width - float_width) / 2)

    -- Create buffer
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })

    -- Create floating window
    local winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = float_width,
      height = float_height,
      row = row,
      col = col,
      style = "minimal",
      border = opts.border or "rounded",
      title = opts.title or " Claude Code ",
      title_pos = "center",
    })

    state.bufnr = bufnr
    return winid
  elseif position == "vertical" then
    local cols = math.floor(vim.o.columns * width)
    vim.cmd("botright " .. cols .. "vsplit")
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, state.bufnr)
    return vim.api.nvim_get_current_win()
  elseif position == "horizontal" then
    local rows = math.floor(vim.o.lines * height)
    vim.cmd("botright " .. rows .. "split")
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, state.bufnr)
    return vim.api.nvim_get_current_win()
  elseif position == "tab" then
    vim.cmd("tabnew")
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, state.bufnr)
    return vim.api.nvim_get_current_win()
  else
    -- Default to vertical
    local cols = math.floor(vim.o.columns * width)
    vim.cmd("botright " .. cols .. "vsplit")
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, state.bufnr)
    return vim.api.nvim_get_current_win()
  end
end

--- Open terminal with command
--- @param cmd string|string[] Command to run
--- @param env table|nil Environment variables
--- @param opts table|nil Options { cwd, position, width, height, on_exit, on_open }
--- @return boolean success
function M.open(cmd, env, opts)
  opts = opts or {}

  -- Close existing terminal if open
  if state.job_id then
    M.close()
  end

  -- Create window
  state.winid = create_window(opts.position or "vertical", opts)

  -- Build command string
  local cmd_str
  if type(cmd) == "table" then
    cmd_str = table.concat(cmd, " ")
  else
    cmd_str = cmd
  end

  -- Set up environment
  local term_env = vim.tbl_extend("force", vim.fn.environ(), env or {})

  -- Open terminal in buffer
  local job_id = vim.fn.termopen(cmd_str, {
    cwd = opts.cwd,
    env = term_env,
    on_exit = function(_, exit_code, _)
      state.job_id = nil
      state.channel = nil
      if opts.on_exit then
        opts.on_exit(exit_code)
      end
    end,
  })

  if job_id <= 0 then
    vim.notify("[prism.nvim] Failed to start terminal", vim.log.levels.ERROR)
    return false
  end

  state.job_id = job_id
  state.channel = job_id

  -- Set buffer options (protect from being used as edit target)
  vim.api.nvim_set_option_value("buftype", "terminal", { buf = state.bufnr })
  vim.api.nvim_set_option_value("buflisted", false, { buf = state.bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.bufnr })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.bufnr })
  vim.api.nvim_buf_set_name(state.bufnr, "prism://claude")
  vim.bo[state.bufnr].filetype = "prism"

  -- Set window options (protect layout)
  vim.api.nvim_set_option_value("number", false, { win = state.winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = state.winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = state.winid })
  vim.api.nvim_set_option_value("winfixwidth", true, { win = state.winid })
  vim.api.nvim_set_option_value("winfixheight", true, { win = state.winid })

  -- Setup terminal keymaps for better navigation
  -- Stay in normal mode by default, press 'i' to type
  local bufnr = state.bufnr
  local kopts = { buffer = bufnr, silent = true }

  -- Enter terminal mode with i/a/A (like vim insert)
  vim.keymap.set("n", "i", "i", { buffer = bufnr, silent = true, desc = "Enter terminal mode" })
  vim.keymap.set("n", "a", "a", { buffer = bufnr, silent = true, desc = "Enter terminal mode" })
  vim.keymap.set("n", "A", "A", { buffer = bufnr, silent = true, desc = "Enter terminal mode" })

  -- Easy escape from terminal mode back to normal mode
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], kopts)
  vim.keymap.set("t", "<C-[>", [[<C-\><C-n>]], kopts)

  -- Navigate between windows from terminal mode
  vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], kopts)
  vim.keymap.set("t", "<C-j>", [[<C-\><C-n><C-w>j]], kopts)
  vim.keymap.set("t", "<C-k>", [[<C-\><C-n><C-w>k]], kopts)
  vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], kopts)

  -- Quick toggle from terminal mode
  vim.keymap.set("t", "<C-\\>", [[<C-\><C-n>:PrismToggle<CR>]], kopts)

  -- Stay in normal mode (don't auto-enter insert)
  vim.cmd("stopinsert")

  -- Setup autocmds for resize on events
  setup_autocmds()

  -- Start continuous resize monitoring to catch cc-status appearance
  start_resize_monitor()

  if opts.on_open then
    vim.schedule(function()
      opts.on_open(state)
    end)
  end

  return true
end

--- Close terminal
--- @return boolean success
function M.close()
  -- Stop resize timer
  if state.resize_timer then
    pcall(vim.fn.timer_stop, state.resize_timer)
    state.resize_timer = nil
  end

  -- Remove autocmds
  if state.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.autocmd_group)
    state.autocmd_group = nil
  end

  -- Stop job if running
  if state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
    state.job_id = nil
    state.channel = nil
  end

  -- Close window if exists
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
    state.winid = nil
  end

  -- Delete buffer if exists
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
    state.bufnr = nil
  end

  return true
end

--- Toggle terminal visibility
--- @return boolean visible New visibility state
function M.toggle()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return false
  end

  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    -- Hide terminal (but can't hide last window)
    local wins = vim.api.nvim_tabpage_list_wins(0)
    if #wins <= 1 then
      -- Last window - create a new empty buffer first
      vim.cmd("enew")
      state.winid = nil
      return false
    end
    vim.api.nvim_win_hide(state.winid)
    state.winid = nil
    return false
  else
    -- Show terminal in new window
    local cols = math.floor(vim.o.columns * 0.4)
    vim.cmd("botright " .. cols .. "vsplit")
    state.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.winid, state.bufnr)

    -- Set window options (protect layout)
    vim.api.nvim_set_option_value("number", false, { win = state.winid })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.winid })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.winid })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = state.winid })
    vim.api.nvim_set_option_value("winfixheight", true, { win = state.winid })

    -- Stay in normal mode for navigation
    vim.cmd("stopinsert")

    -- Re-setup autocmds and start resize monitoring
    setup_autocmds()
    start_resize_monitor()

    return true
  end
end

--- Get terminal buffer number
--- @return number|nil bufnr
function M.get_bufnr()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end
  return nil
end

--- Check if terminal is visible
--- @return boolean
function M.is_visible()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

--- Send text to terminal
--- @param text string Text to send
--- @return boolean success
function M.send(text)
  if not state.channel then
    return false
  end

  local ok = pcall(vim.fn.chansend, state.channel, text)
  return ok
end

--- Get terminal state for advanced operations
--- @return table state
function M.get_terminal()
  return vim.deepcopy(state)
end

--- Check if terminal job is running
--- @return boolean
function M.is_running()
  if not state.job_id then
    return false
  end
  local status = vim.fn.jobwait({ state.job_id }, 0)[1]
  return status == -1 -- -1 means still running
end

--- Force terminal resize (exposed for manual triggering)
--- @return boolean success
function M.resize()
  return trigger_resize()
end

return M
