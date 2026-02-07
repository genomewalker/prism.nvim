--- prism.nvim git hunk parsing and operations
--- Parse unified diffs and apply/stage/unstage hunks
--- @module prism.git.hunk

local M = {}

--- Hunk structure
--- @class Hunk
--- @field old_start number Starting line in old file
--- @field old_count number Number of lines in old file
--- @field new_start number Starting line in new file
--- @field new_count number Number of lines in new file
--- @field lines string[] Hunk content lines (with +/-/space prefix)
--- @field header string Original hunk header (@@ ... @@)

--- Parse unified diff output into hunks
--- @param output string|string[] Diff output (unified format)
--- @return Hunk[] hunks Parsed hunks
--- @return string|nil file_path Parsed file path
function M.parse_diff(output)
  local lines
  if type(output) == "string" then
    lines = vim.split(output, "\n", { plain = true })
  else
    lines = output
  end

  local hunks = {}
  local file_path = nil
  local current_hunk = nil

  for _, line in ipairs(lines) do
    -- Parse file path from --- or +++ lines
    if line:match("^%-%-%- a/") then
      file_path = line:match("^%-%-%- a/(.+)$")
    elseif line:match("^%+%+%+ b/") then
      file_path = file_path or line:match("^%+%+%+ b/(.+)$")
    elseif line:match("^@@") then
      -- New hunk header: @@ -old_start,old_count +new_start,new_count @@
      if current_hunk then
        table.insert(hunks, current_hunk)
      end

      local old_start, old_count, new_start, new_count =
        line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

      if old_start then
        current_hunk = {
          old_start = tonumber(old_start),
          old_count = tonumber(old_count) or 1,
          new_start = tonumber(new_start),
          new_count = tonumber(new_count) or 1,
          header = line,
          lines = {},
        }
      end
    elseif current_hunk then
      -- Hunk content: lines starting with +, -, or space
      if line:match("^[%+%- ]") or line == "" then
        table.insert(current_hunk.lines, line)
      elseif line:match("^\\ No newline") then
        -- Handle "\ No newline at end of file"
        table.insert(current_hunk.lines, line)
      end
    end
  end

  -- Add last hunk
  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks, file_path
end

--- Get additions and deletions from a hunk
--- @param hunk Hunk The hunk to analyze
--- @return string[] additions Lines added
--- @return string[] deletions Lines deleted
--- @return string[] context Context lines
function M.get_changes(hunk)
  local additions = {}
  local deletions = {}
  local context = {}

  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    local content = line:sub(2)

    if prefix == "+" then
      table.insert(additions, content)
    elseif prefix == "-" then
      table.insert(deletions, content)
    elseif prefix == " " then
      table.insert(context, content)
    end
  end

  return additions, deletions, context
end

--- Format hunk as a patch
--- @param hunk Hunk The hunk to format
--- @param file_path string The file path
--- @return string patch Formatted patch
function M.format_patch(hunk, file_path)
  local lines = {
    "--- a/" .. file_path,
    "+++ b/" .. file_path,
    hunk.header,
  }

  for _, line in ipairs(hunk.lines) do
    table.insert(lines, line)
  end

  return table.concat(lines, "\n") .. "\n"
end

--- Apply a hunk using git apply
--- @param hunk Hunk The hunk to apply
--- @param file_path string The file path
--- @param mode string Apply mode: "stage", "unstage", "apply", "discard"
--- @param root string|nil Git root directory
--- @return boolean success
--- @return string|nil error_message
function M.apply_hunk(hunk, file_path, mode, root)
  root = root or vim.fn.getcwd()
  local patch = M.format_patch(hunk, file_path)

  local cmd
  if mode == "stage" then
    cmd = { "git", "-C", root, "apply", "--cached", "-" }
  elseif mode == "unstage" then
    cmd = { "git", "-C", root, "apply", "--cached", "--reverse", "-" }
  elseif mode == "apply" then
    cmd = { "git", "-C", root, "apply", "-" }
  elseif mode == "discard" then
    cmd = { "git", "-C", root, "apply", "--reverse", "-" }
  else
    return false, "Invalid mode: " .. tostring(mode)
  end

  -- Run git apply with patch on stdin
  local result = vim.fn.system(cmd, patch)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return false, result
  end

  return true, nil
end

--- Stage a hunk
--- @param hunk Hunk The hunk to stage
--- @param file_path string The file path
--- @param root string|nil Git root directory
--- @return boolean success
--- @return string|nil error_message
function M.stage_hunk(hunk, file_path, root)
  return M.apply_hunk(hunk, file_path, "stage", root)
end

--- Unstage a hunk
--- @param hunk Hunk The hunk to unstage
--- @param file_path string The file path
--- @param root string|nil Git root directory
--- @return boolean success
--- @return string|nil error_message
function M.unstage_hunk(hunk, file_path, root)
  return M.apply_hunk(hunk, file_path, "unstage", root)
end

--- Discard a hunk (revert changes)
--- @param hunk Hunk The hunk to discard
--- @param file_path string The file path
--- @param root string|nil Git root directory
--- @return boolean success
--- @return string|nil error_message
function M.discard_hunk(hunk, file_path, root)
  return M.apply_hunk(hunk, file_path, "discard", root)
end

--- Find hunk containing a specific line
--- @param hunks Hunk[] List of hunks
--- @param line number Line number in new file
--- @return Hunk|nil hunk The hunk containing the line
--- @return number|nil index The index of the hunk
function M.find_hunk_at_line(hunks, line)
  for i, hunk in ipairs(hunks) do
    local start_line = hunk.new_start
    local end_line = start_line + hunk.new_count - 1

    if line >= start_line and line <= end_line then
      return hunk, i
    end
  end
  return nil, nil
end

--- Get line ranges affected by a hunk in the new file
--- @param hunk Hunk The hunk
--- @return number start_line
--- @return number end_line
function M.get_line_range(hunk)
  return hunk.new_start, hunk.new_start + hunk.new_count - 1
end

--- Count additions and deletions in a hunk
--- @param hunk Hunk The hunk to analyze
--- @return number additions
--- @return number deletions
function M.count_changes(hunk)
  local additions = 0
  local deletions = 0

  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    if prefix == "+" then
      additions = additions + 1
    elseif prefix == "-" then
      deletions = deletions + 1
    end
  end

  return additions, deletions
end

--- Create a summary of hunk changes
--- @param hunk Hunk The hunk
--- @return string summary Human-readable summary
function M.summarize(hunk)
  local additions, deletions = M.count_changes(hunk)
  local parts = {}

  if additions > 0 then
    table.insert(parts, "+" .. additions)
  end
  if deletions > 0 then
    table.insert(parts, "-" .. deletions)
  end

  local range = string.format("L%d-%d", hunk.new_start, hunk.new_start + hunk.new_count - 1)

  return range .. " (" .. table.concat(parts, "/") .. ")"
end

return M
