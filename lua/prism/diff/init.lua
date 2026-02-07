--- prism.nvim diff orchestrator
--- Main interface for inline diff functionality
--- @module prism.diff

local compute = require("prism.diff.compute")
local extmarks = require("prism.diff.extmarks")

local M = {}

--- Active diff sessions by file path
--- @type table<string, table>
local active_diffs = {}

--- Current hunk index per file (for navigation)
--- @type table<string, number>
local current_hunk_index = {}

--- Initialize the diff module
function M.setup()
  extmarks.setup_highlights()
end

--- Open a diff view for a file
--- @param file string File path
--- @param old_content string Original file content
--- @param new_content string New file content
--- @return table|nil Diff session or nil if no changes
function M.open(file, old_content, new_content)
  -- Compute the diff
  local hunks = compute.compute_from_strings(old_content, new_content, file)

  if #hunks == 0 then
    vim.notify("[prism.nvim] No differences found", vim.log.levels.INFO)
    return nil
  end

  -- Find or open the buffer for this file
  local bufnr = vim.fn.bufnr(file)
  if bufnr == -1 then
    -- File not open, open it
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    bufnr = vim.api.nvim_get_current_buf()
  else
    -- Switch to existing buffer
    vim.api.nvim_set_current_buf(bufnr)
  end

  -- Store the diff session
  local session = {
    file = file,
    bufnr = bufnr,
    old_content = old_content,
    new_content = new_content,
    hunks = hunks,
    original_lines = vim.split(old_content, "\n", { plain = true }),
  }

  active_diffs[file] = session
  current_hunk_index[file] = 1

  -- Render all hunks
  for _, hunk in ipairs(hunks) do
    hunk.extmark_ids = extmarks.render_hunk(bufnr, hunk)
  end

  -- Emit event
  local ok, ev = pcall(require, "prism.event")
  if ok then
    ev.emit("diff:created", {
      file = file,
      hunk_count = #hunks,
    })
  end

  -- Jump to first hunk
  M.goto_hunk(file, 1)

  vim.notify(string.format("[prism.nvim] Found %d change(s) in %s", #hunks, vim.fn.fnamemodify(file, ":t")), vim.log.levels.INFO)

  return session
end

--- Accept a specific hunk
--- @param hunk_id number|nil Hunk ID (nil for current hunk)
--- @param file string|nil File path (nil for current file)
--- @return boolean success
function M.accept_hunk(hunk_id, file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    vim.notify("[prism.nvim] No active diff for this file", vim.log.levels.WARN)
    return false
  end

  -- Find the hunk
  local hunk, hunk_idx
  if hunk_id then
    for i, h in ipairs(session.hunks) do
      if h.id == hunk_id then
        hunk = h
        hunk_idx = i
        break
      end
    end
  else
    -- Use current hunk
    hunk_idx = current_hunk_index[file] or 1
    hunk = session.hunks[hunk_idx]
  end

  if not hunk then
    vim.notify("[prism.nvim] Hunk not found", vim.log.levels.WARN)
    return false
  end

  if hunk.status ~= "pending" then
    vim.notify("[prism.nvim] Hunk already " .. hunk.status, vim.log.levels.INFO)
    return false
  end

  -- Apply the hunk to the buffer
  local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
  local new_lines = compute.apply_hunk(lines, hunk)
  vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, new_lines)

  -- Update hunk status
  hunk.status = "accepted"

  -- Update visual state
  extmarks.update_hunk_state(session.bufnr, hunk, "accepted")

  -- Adjust line numbers for subsequent hunks
  local offset = compute.get_hunk_offset(hunk)
  for i = hunk_idx + 1, #session.hunks do
    local h = session.hunks[i]
    if h.status == "pending" then
      h.start_line = h.start_line + offset
      h.end_line = h.end_line + offset
      h.old_start = h.old_start + offset
      -- Re-render with updated positions
      extmarks.clear_hunk(session.bufnr, h)
      h.extmark_ids = extmarks.render_hunk(session.bufnr, h)
    end
  end

  -- Emit event
  local ok, ev = pcall(require, "prism.event")
  if ok then
    ev.emit("diff:hunk:accepted", {
      file = file,
      hunk_id = hunk.id,
    })
  end

  -- Move to next pending hunk or close
  M.next_hunk(file)

  return true
end

--- Reject a specific hunk
--- @param hunk_id number|nil Hunk ID (nil for current hunk)
--- @param file string|nil File path (nil for current file)
--- @return boolean success
function M.reject_hunk(hunk_id, file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    vim.notify("[prism.nvim] No active diff for this file", vim.log.levels.WARN)
    return false
  end

  -- Find the hunk
  local hunk
  if hunk_id then
    for _, h in ipairs(session.hunks) do
      if h.id == hunk_id then
        hunk = h
        break
      end
    end
  else
    -- Use current hunk
    local idx = current_hunk_index[file] or 1
    hunk = session.hunks[idx]
  end

  if not hunk then
    vim.notify("[prism.nvim] Hunk not found", vim.log.levels.WARN)
    return false
  end

  if hunk.status ~= "pending" then
    vim.notify("[prism.nvim] Hunk already " .. hunk.status, vim.log.levels.INFO)
    return false
  end

  -- Just mark as rejected, don't modify buffer
  hunk.status = "rejected"

  -- Update visual state
  extmarks.update_hunk_state(session.bufnr, hunk, "rejected")

  -- Emit event
  local ok, ev = pcall(require, "prism.event")
  if ok then
    ev.emit("diff:hunk:rejected", {
      file = file,
      hunk_id = hunk.id,
    })
  end

  -- Move to next pending hunk
  M.next_hunk(file)

  return true
end

--- Accept all pending hunks
--- Apply from bottom to top to avoid line number invalidation
--- @param file string|nil File path (nil for current file)
--- @return number Number of hunks accepted
function M.accept_all(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    vim.notify("[prism.nvim] No active diff for this file", vim.log.levels.WARN)
    return 0
  end

  -- Get pending hunks sorted by line number descending (bottom to top)
  local pending = {}
  for _, hunk in ipairs(session.hunks) do
    if hunk.status == "pending" then
      table.insert(pending, hunk)
    end
  end

  table.sort(pending, function(a, b)
    return a.start_line > b.start_line
  end)

  -- Apply each hunk from bottom to top
  local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
  local count = 0

  for _, hunk in ipairs(pending) do
    lines = compute.apply_hunk(lines, hunk)
    hunk.status = "accepted"
    extmarks.clear_hunk(session.bufnr, hunk)
    count = count + 1
  end

  -- Update buffer once with all changes
  vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)

  -- Clear all extmarks and close
  extmarks.clear_all(session.bufnr)

  local ok, ev = pcall(require, "prism.event")
  if ok then
    ev.emit("diff:all:accepted", {
      file = file,
      hunk_count = count,
    })
  end

  vim.notify(string.format("[prism.nvim] Accepted %d change(s)", count), vim.log.levels.INFO)

  -- Check if we should auto-close
  local config_ok, config = pcall(require, "prism.config")
  if config_ok and config.get("diff.auto_close") then
    M.close(file)
  end

  return count
end

--- Reject all pending hunks
--- @param file string|nil File path (nil for current file)
--- @return number Number of hunks rejected
function M.reject_all(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    vim.notify("[prism.nvim] No active diff for this file", vim.log.levels.WARN)
    return 0
  end

  local count = 0
  for _, hunk in ipairs(session.hunks) do
    if hunk.status == "pending" then
      hunk.status = "rejected"
      extmarks.clear_hunk(session.bufnr, hunk)
      count = count + 1
    end
  end

  -- Clear all extmarks
  extmarks.clear_all(session.bufnr)

  local ok, ev = pcall(require, "prism.event")
  if ok then
    ev.emit("diff:all:rejected", {
      file = file,
      hunk_count = count,
    })
  end

  vim.notify(string.format("[prism.nvim] Rejected %d change(s)", count), vim.log.levels.INFO)

  -- Check if we should auto-close
  local config_ok, config = pcall(require, "prism.config")
  if config_ok and config.get("diff.auto_close") then
    M.close(file)
  end

  return count
end

--- Navigate to next pending hunk
--- @param file string|nil File path (nil for current file)
--- @return table|nil Next hunk or nil if none
function M.next_hunk(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    return nil
  end

  local current = current_hunk_index[file] or 0

  -- Find next pending hunk
  for i = current + 1, #session.hunks do
    if session.hunks[i].status == "pending" then
      return M.goto_hunk(file, i)
    end
  end

  -- Wrap around
  for i = 1, current do
    if session.hunks[i].status == "pending" then
      return M.goto_hunk(file, i)
    end
  end

  -- No pending hunks left
  vim.notify("[prism.nvim] No more pending changes", vim.log.levels.INFO)
  return nil
end

--- Navigate to previous pending hunk
--- @param file string|nil File path (nil for current file)
--- @return table|nil Previous hunk or nil if none
function M.prev_hunk(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    return nil
  end

  local current = current_hunk_index[file] or (#session.hunks + 1)

  -- Find previous pending hunk
  for i = current - 1, 1, -1 do
    if session.hunks[i].status == "pending" then
      return M.goto_hunk(file, i)
    end
  end

  -- Wrap around
  for i = #session.hunks, current, -1 do
    if session.hunks[i].status == "pending" then
      return M.goto_hunk(file, i)
    end
  end

  -- No pending hunks
  vim.notify("[prism.nvim] No more pending changes", vim.log.levels.INFO)
  return nil
end

--- Go to a specific hunk by index
--- @param file string File path
--- @param index number Hunk index (1-based)
--- @return table|nil Hunk or nil if invalid
function M.goto_hunk(file, index)
  local session = active_diffs[file]

  if not session or index < 1 or index > #session.hunks then
    return nil
  end

  local hunk = session.hunks[index]
  current_hunk_index[file] = index

  -- Clear previous active highlight
  extmarks.clear_active_highlight(session.bufnr)

  -- Move cursor to hunk start line
  local line = math.max(1, hunk.start_line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })

  -- Highlight this hunk as active
  extmarks.highlight_active(session.bufnr, hunk)

  -- Center the view
  vim.cmd("normal! zz")

  return hunk
end

--- Get all active hunks for a file
--- @param file string|nil File path (nil for current file)
--- @return table[] Array of pending hunks
function M.get_active_hunks(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    return {}
  end

  local pending = {}
  for _, hunk in ipairs(session.hunks) do
    if hunk.status == "pending" then
      table.insert(pending, hunk)
    end
  end

  return pending
end

--- Get current hunk
--- @param file string|nil File path (nil for current file)
--- @return table|nil Current hunk or nil
function M.get_current_hunk(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if not session then
    return nil
  end

  local idx = current_hunk_index[file]
  return idx and session.hunks[idx] or nil
end

--- Close diff view for a file
--- @param file string|nil File path (nil for current file)
function M.close(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local session = active_diffs[file]

  if session then
    -- Clear all extmarks
    extmarks.clear_all(session.bufnr)

    -- Remove from tracking
    active_diffs[file] = nil
    current_hunk_index[file] = nil
  end
end

--- Check if a file has an active diff session
--- @param file string|nil File path (nil for current file)
--- @return boolean
function M.has_active_diff(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  return active_diffs[file] ~= nil
end

--- Get diff session for a file
--- @param file string|nil File path (nil for current file)
--- @return table|nil Session or nil
function M.get_session(file)
  file = file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  return active_diffs[file]
end

--- Get summary of all active diff sessions
--- @return table Summary { file = { pending = n, accepted = n, rejected = n } }
function M.summary()
  local result = {}

  for file, session in pairs(active_diffs) do
    local counts = { pending = 0, accepted = 0, rejected = 0 }
    for _, hunk in ipairs(session.hunks) do
      counts[hunk.status] = (counts[hunk.status] or 0) + 1
    end
    result[file] = counts
  end

  return result
end

return M
