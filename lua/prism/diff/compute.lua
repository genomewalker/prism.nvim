--- prism.nvim diff computation module
--- Uses vim.diff() for computing inline diffs
--- @module prism.diff.compute

local M = {}

--- Hunk counter for unique IDs
local hunk_counter = 0

--- Generate unique hunk ID
--- @return number
local function next_hunk_id()
  hunk_counter = hunk_counter + 1
  return hunk_counter
end

--- Reset hunk counter (for testing)
function M.reset_counter()
  hunk_counter = 0
end

--- Parse a unified diff hunk header
--- Format: @@ -old_start,old_count +new_start,new_count @@
--- @param header string The @@ header line
--- @return number|nil old_start
--- @return number|nil old_count
--- @return number|nil new_start
--- @return number|nil new_count
local function parse_hunk_header(header)
  local old_start, old_count, new_start, new_count =
    header:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@")

  if not old_start then
    -- Try without counts (single line changes)
    old_start, new_start = header:match("^@@%s+%-(%d+)%s+%+(%d+)%s+@@")
    old_count = "1"
    new_count = "1"
  end

  if not old_start then
    return nil, nil, nil, nil
  end

  return tonumber(old_start),
         tonumber(old_count) or 1,
         tonumber(new_start),
         tonumber(new_count) or 1
end

--- Compute diff between two sets of lines
--- @param old_lines string[] Original lines
--- @param new_lines string[] New lines
--- @param file string|nil File path for hunk metadata
--- @return table[] Array of hunk objects
function M.compute(old_lines, new_lines, file)
  if not old_lines or not new_lines then
    return {}
  end

  -- Join lines with newlines for vim.diff
  local old_text = table.concat(old_lines, "\n")
  local new_text = table.concat(new_lines, "\n")

  -- Add trailing newlines if content is non-empty
  if #old_text > 0 then
    old_text = old_text .. "\n"
  end
  if #new_text > 0 then
    new_text = new_text .. "\n"
  end

  -- Compute unified diff
  local diff_text = vim.diff(old_text, new_text, {
    result_type = "unified",
    ctxlen = 0, -- No context lines, just changes
  })

  if not diff_text or diff_text == "" then
    return {} -- No differences
  end

  -- Parse the unified diff output
  local hunks = {}
  local diff_lines = vim.split(diff_text, "\n", { plain = true })

  local i = 1
  while i <= #diff_lines do
    local line = diff_lines[i]

    -- Look for hunk headers
    if line:match("^@@") then
      local old_start, old_count, new_start, new_count = parse_hunk_header(line)

      if old_start then
        local hunk = {
          id = next_hunk_id(),
          file = file or "",
          start_line = new_start,
          end_line = new_start + new_count - 1,
          old_start = old_start,
          old_count = old_count,
          new_count = new_count,
          old_lines = {},
          new_lines = {},
          status = "pending",
          extmark_ids = {},
        }

        -- Collect the hunk content
        i = i + 1
        while i <= #diff_lines do
          local content_line = diff_lines[i]

          -- Stop at next hunk header or end
          if content_line:match("^@@") or content_line == "" and i == #diff_lines then
            break
          end

          local prefix = content_line:sub(1, 1)
          local text = content_line:sub(2)

          if prefix == "-" then
            table.insert(hunk.old_lines, text)
          elseif prefix == "+" then
            table.insert(hunk.new_lines, text)
          elseif prefix == " " then
            -- Context line (shouldn't happen with ctxlen=0)
            table.insert(hunk.old_lines, text)
            table.insert(hunk.new_lines, text)
          end

          i = i + 1
        end

        -- Determine hunk type for easier rendering
        if #hunk.old_lines == 0 and #hunk.new_lines > 0 then
          hunk.type = "add"
        elseif #hunk.old_lines > 0 and #hunk.new_lines == 0 then
          hunk.type = "delete"
        else
          hunk.type = "change"
        end

        table.insert(hunks, hunk)
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  return hunks
end

--- Compute diff from strings (convenience wrapper)
--- @param old_content string Original content as single string
--- @param new_content string New content as single string
--- @param file string|nil File path
--- @return table[] Array of hunks
function M.compute_from_strings(old_content, new_content, file)
  local old_lines = vim.split(old_content or "", "\n", { plain = true })
  local new_lines = vim.split(new_content or "", "\n", { plain = true })
  return M.compute(old_lines, new_lines, file)
end

--- Apply a single hunk to buffer content
--- Returns new buffer lines after applying the hunk
--- @param buffer_lines string[] Current buffer lines
--- @param hunk table The hunk to apply
--- @return string[] New buffer lines
function M.apply_hunk(buffer_lines, hunk)
  local result = vim.deepcopy(buffer_lines)

  if hunk.type == "add" then
    -- Insert new lines at start_line position
    local insert_pos = hunk.start_line
    for i, line in ipairs(hunk.new_lines) do
      table.insert(result, insert_pos + i - 1, line)
    end
  elseif hunk.type == "delete" then
    -- Remove old lines starting at old_start
    for _ = 1, #hunk.old_lines do
      if result[hunk.old_start] then
        table.remove(result, hunk.old_start)
      end
    end
  else -- change
    -- Replace old lines with new lines
    -- First remove old lines
    for _ = 1, #hunk.old_lines do
      if result[hunk.old_start] then
        table.remove(result, hunk.old_start)
      end
    end
    -- Then insert new lines
    for i, line in ipairs(hunk.new_lines) do
      table.insert(result, hunk.old_start + i - 1, line)
    end
  end

  return result
end

--- Revert a single hunk (undo the change)
--- @param buffer_lines string[] Current buffer lines
--- @param hunk table The hunk to revert
--- @return string[] Original buffer lines
function M.revert_hunk(buffer_lines, hunk)
  local result = vim.deepcopy(buffer_lines)

  if hunk.type == "add" then
    -- Remove the added lines
    for _ = 1, #hunk.new_lines do
      if result[hunk.start_line] then
        table.remove(result, hunk.start_line)
      end
    end
  elseif hunk.type == "delete" then
    -- Re-insert the deleted lines
    for i, line in ipairs(hunk.old_lines) do
      table.insert(result, hunk.old_start + i - 1, line)
    end
  else -- change
    -- Replace new lines with old lines
    for _ = 1, #hunk.new_lines do
      if result[hunk.start_line] then
        table.remove(result, hunk.start_line)
      end
    end
    for i, line in ipairs(hunk.old_lines) do
      table.insert(result, hunk.start_line + i - 1, line)
    end
  end

  return result
end

--- Get line offset caused by accepting a hunk
--- Used to adjust subsequent hunk positions
--- @param hunk table The hunk
--- @return number Line offset (positive = lines added, negative = lines removed)
function M.get_hunk_offset(hunk)
  return #hunk.new_lines - #hunk.old_lines
end

return M
