--- prism.nvim extmark rendering for inline diffs
--- Handles visual presentation of diff hunks using Neovim extmarks
--- @module prism.diff.extmarks

local M = {}

--- Namespace for all prism diff extmarks
local ns_id = nil

--- Get or create namespace
--- @return number Namespace ID
local function get_namespace()
  if not ns_id then
    ns_id = vim.api.nvim_create_namespace("prism_diff")
  end
  return ns_id
end

--- Setup highlight groups for diff rendering
function M.setup_highlights()
  -- Line highlights
  vim.api.nvim_set_hl(0, "PrismDiffAdd", { bg = "#1e3a2f", default = true })
  vim.api.nvim_set_hl(0, "PrismDiffDelete", { bg = "#3a1e1e", default = true })
  vim.api.nvim_set_hl(0, "PrismDiffChange", { bg = "#3a3a1e", default = true })

  -- Virtual line highlights (for showing old/new content)
  vim.api.nvim_set_hl(0, "PrismDiffAddVirt", { fg = "#88c088", bg = "#1e3a2f", default = true })
  vim.api.nvim_set_hl(0, "PrismDiffDelVirt", { fg = "#c08888", bg = "#3a1e1e", strikethrough = true, default = true })
  vim.api.nvim_set_hl(0, "PrismDiffChangeVirt", { fg = "#c0c088", bg = "#3a3a1e", default = true })

  -- Sign column
  vim.api.nvim_set_hl(0, "PrismDiffAddSign", { fg = "#88c088", default = true })
  vim.api.nvim_set_hl(0, "PrismDiffDelSign", { fg = "#c08888", default = true })
  vim.api.nvim_set_hl(0, "PrismDiffChangeSign", { fg = "#c0c088", default = true })

  -- Accepted/rejected states
  vim.api.nvim_set_hl(0, "PrismDiffAccepted", { fg = "#88c088", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PrismDiffRejected", { fg = "#c08888", bold = true, default = true })
end

--- Get sign text for hunk type
--- @param hunk_type string "add" | "delete" | "change"
--- @param config table|nil Config with custom signs
--- @return string Sign text
local function get_sign(hunk_type, config)
  local signs = config and config.signs or {
    add = "+",
    delete = "-",
    change = "~",
  }
  return signs[hunk_type] or "~"
end

--- Get highlight group for hunk type
--- @param hunk_type string "add" | "delete" | "change"
--- @param variant string|nil "line" | "virt" | "sign"
--- @return string Highlight group name
local function get_hl_group(hunk_type, variant)
  local base = ({
    add = "PrismDiffAdd",
    delete = "PrismDiffDelete",
    change = "PrismDiffChange",
  })[hunk_type] or "PrismDiffChange"

  if variant == "virt" then
    return base .. "Virt"
  elseif variant == "sign" then
    return base .. "Sign"
  end
  return base
end

--- Render a hunk with extmarks
--- @param bufnr number Buffer number
--- @param hunk table Hunk object
--- @param config table|nil Configuration
--- @return number[] Array of extmark IDs created
function M.render_hunk(bufnr, hunk, config)
  local ns = get_namespace()
  local extmark_ids = {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Safety: ensure we're working with valid line numbers
  local start_line = math.max(0, (hunk.start_line or 1) - 1) -- Convert to 0-indexed
  start_line = math.min(start_line, line_count - 1)

  if hunk.type == "add" then
    -- For additions: show virtual lines above where content will be added
    -- The new lines aren't in the buffer yet, show them as virtual
    local virt_lines = {}
    for _, line in ipairs(hunk.new_lines) do
      table.insert(virt_lines, { { "+" .. line, get_hl_group("add", "virt") } })
    end

    if #virt_lines > 0 and start_line >= 0 then
      local id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        sign_text = get_sign("add", config),
        sign_hl_group = get_hl_group("add", "sign"),
        priority = 100,
      })
      table.insert(extmark_ids, id)
    end

  elseif hunk.type == "delete" then
    -- For deletions: highlight lines to be removed and show strikethrough
    for i = 0, #hunk.old_lines - 1 do
      local line_idx = start_line + i
      if line_idx >= 0 and line_idx < line_count then
        local id = vim.api.nvim_buf_set_extmark(bufnr, ns, line_idx, 0, {
          line_hl_group = get_hl_group("delete"),
          sign_text = get_sign("delete", config),
          sign_hl_group = get_hl_group("delete", "sign"),
          priority = 100,
        })
        table.insert(extmark_ids, id)
      end
    end

  else -- change
    -- For changes: show old lines with strikethrough, new lines as virtual

    -- First, highlight the existing lines (old content)
    for i = 0, #hunk.old_lines - 1 do
      local line_idx = start_line + i
      if line_idx >= 0 and line_idx < line_count then
        local id = vim.api.nvim_buf_set_extmark(bufnr, ns, line_idx, 0, {
          line_hl_group = get_hl_group("change"),
          sign_text = get_sign("change", config),
          sign_hl_group = get_hl_group("change", "sign"),
          priority = 100,
        })
        table.insert(extmark_ids, id)
      end
    end

    -- Then show new lines as virtual lines below the changed region
    local virt_lines = {}
    for _, line in ipairs(hunk.new_lines) do
      table.insert(virt_lines, { { ">" .. line, get_hl_group("add", "virt") } })
    end

    if #virt_lines > 0 then
      local virt_pos = math.min(start_line + #hunk.old_lines - 1, line_count - 1)
      if virt_pos >= 0 then
        local id = vim.api.nvim_buf_set_extmark(bufnr, ns, virt_pos, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
          priority = 100,
        })
        table.insert(extmark_ids, id)
      end
    end
  end

  return extmark_ids
end

--- Clear extmarks for a specific hunk
--- @param bufnr number Buffer number
--- @param hunk table Hunk object with extmark_ids
function M.clear_hunk(bufnr, hunk)
  local ns = get_namespace()

  if hunk.extmark_ids then
    for _, id in ipairs(hunk.extmark_ids) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
    end
  end
end

--- Clear all prism diff extmarks from a buffer
--- @param bufnr number Buffer number
function M.clear_all(bufnr)
  local ns = get_namespace()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Update hunk visual state (e.g., after accept/reject)
--- @param bufnr number Buffer number
--- @param hunk table Hunk object
--- @param state string "accepted" | "rejected"
function M.update_hunk_state(bufnr, hunk, state)
  -- First clear existing extmarks
  M.clear_hunk(bufnr, hunk)

  local ns = get_namespace()
  local start_line = math.max(0, (hunk.start_line or 1) - 1)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  if start_line >= line_count then
    start_line = math.max(0, line_count - 1)
  end

  -- Add a brief indicator that the hunk was processed
  local hl_group = state == "accepted" and "PrismDiffAccepted" or "PrismDiffRejected"
  local sign = state == "accepted" and "✓" or "✗"

  local id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
    sign_text = sign,
    sign_hl_group = hl_group,
    priority = 200,
    -- Auto-clear after a delay would require a timer
  })

  hunk.extmark_ids = { id }
end

--- Highlight a specific hunk as active (for navigation)
--- @param bufnr number Buffer number
--- @param hunk table Hunk object
function M.highlight_active(bufnr, hunk)
  local ns = get_namespace()
  local start_line = math.max(0, (hunk.start_line or 1) - 1)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  if start_line < line_count then
    vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
      line_hl_group = "CursorLine",
      priority = 150,
      id = 999999, -- Reserved ID for active highlight
    })
  end
end

--- Clear active highlight
--- @param bufnr number Buffer number
function M.clear_active_highlight(bufnr)
  local ns = get_namespace()
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, 999999)
end

--- Get namespace ID (for external use)
--- @return number Namespace ID
function M.get_namespace()
  return get_namespace()
end

return M
