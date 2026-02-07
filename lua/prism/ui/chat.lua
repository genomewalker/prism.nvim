--- prism.nvim chat panel
--- @module prism.ui.chat

local M = {}

--- State
local state = {
  layout = nil,
  output_popup = nil,
  input_component = nil,
  is_open = false,
  history = {},
  history_index = 0,
}

--- Configuration
local config = {
  width = 80,
  height = 30,
  border = "rounded",
  title = " Claude Chat ",
  input_height = 3,
}

--- Icons
local icons = {
  user = "",
  assistant = "󰚩",
  system = "",
  thinking = "",
}

--- Setup nui components
--- @return boolean success
local function setup_components()
  local ok_popup, Popup = pcall(require, "nui.popup")
  local ok_input, Input = pcall(require, "nui.input")
  local ok_layout, Layout = pcall(require, "nui.layout")

  if not (ok_popup and ok_input and ok_layout) then
    require("prism.ui.notify").error("nui.nvim is required for chat UI")
    return false
  end

  -- Calculate dimensions
  local ui = vim.api.nvim_list_uis()[1]
  local width = math.min(config.width, math.floor(ui.width * 0.9))
  local height = math.min(config.height, math.floor(ui.height * 0.85))

  -- Output popup (chat messages)
  state.output_popup = Popup({
    enter = false,
    focusable = true,
    border = {
      style = config.border,
      text = {
        top = config.title,
        top_align = "center",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "markdown",
    },
    win_options = {
      winblend = 0,
      winhighlight = "Normal:PrismNormal,FloatBorder:PrismBorder,FloatTitle:PrismTitle",
      wrap = true,
      linebreak = true,
      cursorline = false,
    },
  })

  -- Input component
  state.input_component = Input({
    relative = "editor",
    position = "50%",
    border = {
      style = config.border,
      text = {
        top = " Message ",
        top_align = "left",
      },
    },
    buf_options = {
      filetype = "markdown",
    },
    win_options = {
      winblend = 0,
      winhighlight = "Normal:PrismNormal,FloatBorder:PrismBorder",
    },
  }, {
    prompt = "> ",
    on_submit = function(value)
      M.submit(value)
    end,
  })

  -- Create layout
  state.layout = Layout(
    {
      position = "50%",
      size = {
        width = width,
        height = height,
      },
    },
    Layout.Box({
      Layout.Box(state.output_popup, { size = height - config.input_height - 2 }),
      Layout.Box(state.input_component, { size = config.input_height }),
    }, { dir = "col" })
  )

  return true
end

--- Setup keymaps for chat buffers
local function setup_keymaps()
  if not state.output_popup then return end

  local output_buf = state.output_popup.bufnr
  local input_buf = state.input_component.bufnr

  -- Close on Escape or q in output buffer
  if output_buf then
    vim.keymap.set("n", "q", function() M.close() end, { buffer = output_buf, nowait = true })
    vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = output_buf, nowait = true })
    -- Focus input
    vim.keymap.set("n", "i", function()
      if state.input_component and state.input_component.winid then
        vim.api.nvim_set_current_win(state.input_component.winid)
        vim.cmd("startinsert")
      end
    end, { buffer = output_buf, nowait = true })
    -- Scroll bindings
    vim.keymap.set("n", "G", "G", { buffer = output_buf })
    vim.keymap.set("n", "gg", "gg", { buffer = output_buf })
  end

  -- Input buffer keymaps
  if input_buf then
    vim.keymap.set("i", "<Esc>", function()
      vim.cmd("stopinsert")
      if state.output_popup and state.output_popup.winid then
        vim.api.nvim_set_current_win(state.output_popup.winid)
      end
    end, { buffer = input_buf, nowait = true })

    -- History navigation
    vim.keymap.set("i", "<Up>", function()
      if #state.history > 0 then
        state.history_index = math.min(state.history_index + 1, #state.history)
        local msg = state.history[#state.history - state.history_index + 1]
        if msg then
          vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { msg })
          vim.cmd("normal! $")
        end
      end
    end, { buffer = input_buf })

    vim.keymap.set("i", "<Down>", function()
      if state.history_index > 0 then
        state.history_index = state.history_index - 1
        if state.history_index == 0 then
          vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
        else
          local msg = state.history[#state.history - state.history_index + 1]
          if msg then
            vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { msg })
            vim.cmd("normal! $")
          end
        end
      end
    end, { buffer = input_buf })
  end
end

--- Setup chat panel
--- @param opts table|nil Configuration options
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

--- Open the chat panel
function M.open()
  if state.is_open then
    -- Focus input if already open
    if state.input_component and state.input_component.winid then
      vim.api.nvim_set_current_win(state.input_component.winid)
      vim.cmd("startinsert!")
    end
    return
  end

  if not setup_components() then
    return
  end

  state.layout:mount()
  state.is_open = true

  setup_keymaps()

  -- Focus input and start insert mode
  vim.schedule(function()
    if state.input_component and state.input_component.winid then
      vim.api.nvim_set_current_win(state.input_component.winid)
      vim.cmd("startinsert!")
    end
  end)

  -- Emit event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("ui:chat:opened")
  end
end

--- Close the chat panel
function M.close()
  if not state.is_open then return end

  if state.layout then
    state.layout:unmount()
  end

  state.layout = nil
  state.output_popup = nil
  state.input_component = nil
  state.is_open = false

  -- Emit event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("ui:chat:closed")
  end
end

--- Toggle the chat panel
function M.toggle()
  if state.is_open then
    M.close()
  else
    M.open()
  end
end

--- Check if chat is open
--- @return boolean
function M.is_open()
  return state.is_open
end

--- Append text to the chat output
--- @param text string Text to append
--- @param hl_group string|nil Highlight group
function M.append(text, hl_group)
  if not state.output_popup or not state.output_popup.bufnr then return end

  local buf = state.output_popup.bufnr

  -- Make buffer modifiable temporarily
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

  -- Get current lines
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local is_empty = #lines == 1 and lines[1] == ""

  -- Split text into lines
  local new_lines = vim.split(text, "\n", { plain = true })

  if is_empty then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, new_lines)
  end

  -- Apply highlight if specified
  if hl_group then
    local line_count = vim.api.nvim_buf_line_count(buf)
    for i = line_count - #new_lines, line_count - 1 do
      vim.api.nvim_buf_add_highlight(buf, -1, hl_group, i, 0, -1)
    end
  end

  -- Restore readonly
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Scroll to bottom
  if state.output_popup.winid and vim.api.nvim_win_is_valid(state.output_popup.winid) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(state.output_popup.winid, { line_count, 0 })
  end
end

--- Append a user message
--- @param text string
function M.append_user(text)
  M.append(string.format("\n%s You:\n%s", icons.user, text), "PrismChatUser")
end

--- Append an assistant message
--- @param text string
function M.append_assistant(text)
  M.append(string.format("\n%s Claude:\n%s", icons.assistant, text), "PrismChatAssistant")
end

--- Append a system message
--- @param text string
function M.append_system(text)
  M.append(string.format("\n%s %s", icons.system, text), "PrismChatSystem")
end

--- Append an error message
--- @param text string
function M.append_error(text)
  M.append(string.format("\n Error: %s", text), "PrismChatError")
end

--- Clear the chat output
function M.clear()
  if not state.output_popup or not state.output_popup.bufnr then return end

  local buf = state.output_popup.bufnr
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

--- Submit a message
--- @param text string
function M.submit(text)
  if not text or text == "" then return end

  -- Add to history
  table.insert(state.history, text)
  state.history_index = 0

  -- Display user message
  M.append_user(text)

  -- Clear input
  if state.input_component and state.input_component.bufnr then
    vim.api.nvim_buf_set_lines(state.input_component.bufnr, 0, -1, false, { "" })
  end

  -- Emit event
  local ok, event = pcall(require, "prism.event")
  if ok then
    event.emit("chat:message:sent", { message = text })
  end
end

--- Set the chat title
--- @param title string
function M.set_title(title)
  if state.output_popup and state.output_popup.border then
    state.output_popup.border:set_text("top", " " .. title .. " ", "center")
  end
end

--- Get chat history
--- @return table
function M.get_history()
  return vim.deepcopy(state.history)
end

--- Clear chat history
function M.clear_history()
  state.history = {}
  state.history_index = 0
end

return M
