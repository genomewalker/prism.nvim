--- prism.nvim git integration
--- Git operations for context, diffs, and staging
--- @module prism.git

local M = {}

local hunk = require("prism.git.hunk")
local watcher = require("prism.git.watcher")

--- Export submodules
M.hunk = hunk
M.watcher = watcher

--- Cache for git root per buffer
--- @type table<number, string>
local root_cache = {}

--- Protected branches that require confirmation
local PROTECTED_BRANCHES = {
  "main",
  "master",
  "develop",
  "production",
  "release",
}

--- Run git command and return output
--- @param args string[] Git command arguments
--- @param cwd string|nil Working directory
--- @return string|nil output
--- @return number exit_code
local function git_cmd(args, cwd)
  local cmd = vim.list_extend({ "git" }, args)
  if cwd then
    cmd = vim.list_extend({ "git", "-C", cwd }, args)
  end

  local result = vim.fn.system(cmd)
  return result, vim.v.shell_error
end

--- Get git root directory for a path
--- @param path string|nil File or directory path (defaults to cwd)
--- @return string|nil root
function M.root(path)
  path = path or vim.fn.getcwd()

  -- Check cache for buffer
  local bufnr = vim.fn.bufnr(path)
  if bufnr > 0 and root_cache[bufnr] then
    return root_cache[bufnr]
  end

  local output, exit_code = git_cmd({ "rev-parse", "--show-toplevel" }, path)
  if exit_code ~= 0 then
    return nil
  end

  local root = vim.trim(output)

  -- Cache result
  if bufnr > 0 then
    root_cache[bufnr] = root
  end

  return root
end

--- Check if path is in a git repository
--- @param path string|nil Path to check
--- @return boolean
function M.is_repo(path)
  return M.root(path) ~= nil
end

--- Get git status
--- @param path string|nil Path to get status for (nil for all)
--- @param root string|nil Git root directory
--- @return table status { staged = {}, unstaged = {}, untracked = {} }
function M.status(path, root)
  root = root or M.root(path)
  if not root then
    return { staged = {}, unstaged = {}, untracked = {} }
  end

  local args = { "status", "--porcelain=v1" }
  if path then
    table.insert(args, "--")
    table.insert(args, path)
  end

  local output, exit_code = git_cmd(args, root)
  if exit_code ~= 0 then
    return { staged = {}, unstaged = {}, untracked = {} }
  end

  local result = {
    staged = {},
    unstaged = {},
    untracked = {},
  }

  for line in output:gmatch("[^\r\n]+") do
    local index_status = line:sub(1, 1)
    local worktree_status = line:sub(2, 2)
    local file = line:sub(4)

    -- Handle renames
    if file:match(" -> ") then
      file = file:match(" -> (.+)$")
    end

    -- Staged changes
    if index_status ~= " " and index_status ~= "?" then
      table.insert(result.staged, {
        file = file,
        status = index_status,
      })
    end

    -- Unstaged changes
    if worktree_status ~= " " and worktree_status ~= "?" then
      table.insert(result.unstaged, {
        file = file,
        status = worktree_status,
      })
    end

    -- Untracked files
    if index_status == "?" then
      table.insert(result.untracked, {
        file = file,
        status = "?",
      })
    end
  end

  return result
end

--- Get diff for a file
--- @param file string File path (relative to root)
--- @param root string|nil Git root directory
--- @param staged boolean|nil Get staged diff (default: unstaged)
--- @return string diff Unified diff output
function M.diff(file, root, staged)
  root = root or M.root(file)
  if not root then
    return ""
  end

  local args = { "diff" }
  if staged then
    table.insert(args, "--cached")
  end
  table.insert(args, "--")
  table.insert(args, file)

  local output, exit_code = git_cmd(args, root)
  if exit_code ~= 0 then
    return ""
  end

  return output
end

--- Get diff for all files
--- @param root string|nil Git root directory
--- @param staged boolean|nil Get staged diff (default: unstaged)
--- @return string diff Unified diff output
function M.diff_all(root, staged)
  root = root or M.root()
  if not root then
    return ""
  end

  local args = { "diff" }
  if staged then
    table.insert(args, "--cached")
  end

  local output, exit_code = git_cmd(args, root)
  if exit_code ~= 0 then
    return ""
  end

  return output
end

--- Stage a file
--- @param file string File path
--- @param root string|nil Git root directory
--- @return boolean success
function M.stage_file(file, root)
  root = root or M.root(file)
  if not root then
    return false
  end

  local _, exit_code = git_cmd({ "add", "--", file }, root)
  return exit_code == 0
end

--- Unstage a file
--- @param file string File path
--- @param root string|nil Git root directory
--- @return boolean success
function M.unstage_file(file, root)
  root = root or M.root(file)
  if not root then
    return false
  end

  local _, exit_code = git_cmd({ "reset", "HEAD", "--", file }, root)
  return exit_code == 0
end

--- Stage a hunk
--- @param h table Hunk from hunk.parse_diff
--- @param file string File path
--- @param root string|nil Git root directory
--- @return boolean success
--- @return string|nil error_message
function M.stage_hunk(h, file, root)
  root = root or M.root(file)
  return hunk.stage_hunk(h, file, root)
end

--- Unstage a hunk
--- @param h table Hunk from hunk.parse_diff
--- @param file string File path
--- @param root string|nil Git root directory
--- @return boolean success
--- @return string|nil error_message
function M.unstage_hunk(h, file, root)
  root = root or M.root(file)
  return hunk.unstage_hunk(h, file, root)
end

--- Checkout (discard changes in) a file
--- @param file string File path
--- @param root string|nil Git root directory
--- @return boolean success
function M.checkout_file(file, root)
  root = root or M.root(file)
  if not root then
    return false
  end

  local _, exit_code = git_cmd({ "checkout", "--", file }, root)
  return exit_code == 0
end

--- Check if working tree is dirty
--- @param root string|nil Git root directory
--- @return boolean dirty
function M.is_dirty(root)
  root = root or M.root()
  if not root then
    return false
  end

  local output, exit_code = git_cmd({ "status", "--porcelain" }, root)
  if exit_code ~= 0 then
    return false
  end

  return vim.trim(output) ~= ""
end

--- Get current branch name
--- @param root string|nil Git root directory
--- @return string|nil branch
function M.branch(root)
  root = root or M.root()
  if not root then
    return nil
  end

  local output, exit_code = git_cmd({ "rev-parse", "--abbrev-ref", "HEAD" }, root)
  if exit_code ~= 0 then
    return nil
  end

  return vim.trim(output)
end

--- Check if current branch is a protected/safe branch
--- @param root string|nil Git root directory
--- @return boolean is_safe
function M.is_safe_branch(root)
  local current = M.branch(root)
  if not current then
    return true -- Can't determine, assume safe
  end

  for _, protected in ipairs(PROTECTED_BRANCHES) do
    if current == protected then
      return false
    end
  end

  return true
end

--- Get list of protected branches
--- @return string[]
function M.protected_branches()
  return vim.deepcopy(PROTECTED_BRANCHES)
end

--- Get current commit hash
--- @param root string|nil Git root directory
--- @param short boolean|nil Return short hash (default: true)
--- @return string|nil hash
function M.head(root, short)
  root = root or M.root()
  if not root then
    return nil
  end

  short = short ~= false
  local args = { "rev-parse" }
  if short then
    table.insert(args, "--short")
  end
  table.insert(args, "HEAD")

  local output, exit_code = git_cmd(args, root)
  if exit_code ~= 0 then
    return nil
  end

  return vim.trim(output)
end

--- Get file content at a specific revision
--- @param file string File path
--- @param rev string|nil Revision (default: HEAD)
--- @param root string|nil Git root directory
--- @return string|nil content
function M.show(file, rev, root)
  root = root or M.root(file)
  if not root then
    return nil
  end

  rev = rev or "HEAD"
  local output, exit_code = git_cmd({ "show", rev .. ":" .. file }, root)
  if exit_code ~= 0 then
    return nil
  end

  return output
end

--- Get blame for a file
--- @param file string File path
--- @param root string|nil Git root directory
--- @return table[] blame { line, commit, author, date }
function M.blame(file, root)
  root = root or M.root(file)
  if not root then
    return {}
  end

  local output, exit_code = git_cmd({
    "blame",
    "--porcelain",
    "--",
    file,
  }, root)

  if exit_code ~= 0 then
    return {}
  end

  local result = {}
  local current_commit = nil
  local line_num = 0

  for line in output:gmatch("[^\r\n]+") do
    local commit = line:match("^(%x+) %d+ %d+")
    if commit then
      current_commit = {
        commit = commit,
        line = line_num + 1,
      }
      line_num = line_num + 1
    elseif current_commit then
      local author = line:match("^author (.+)$")
      if author then
        current_commit.author = author
      end

      local author_time = line:match("^author%-time (%d+)$")
      if author_time then
        current_commit.date = tonumber(author_time)
      end

      if line:match("^\t") then
        current_commit.content = line:sub(2)
        table.insert(result, current_commit)
        current_commit = nil
      end
    end
  end

  return result
end

--- Get recent commits
--- @param root string|nil Git root directory
--- @param limit number|nil Number of commits (default: 10)
--- @return table[] commits { hash, subject, author, date }
function M.log(root, limit)
  root = root or M.root()
  if not root then
    return {}
  end

  limit = limit or 10
  local output, exit_code = git_cmd({
    "log",
    "-n",
    tostring(limit),
    "--format=%H%x00%s%x00%an%x00%at",
  }, root)

  if exit_code ~= 0 then
    return {}
  end

  local result = {}
  for line in output:gmatch("[^\r\n]+") do
    local hash, subject, author, date = line:match("^([^%z]+)%z([^%z]+)%z([^%z]+)%z([^%z]+)$")
    if hash then
      table.insert(result, {
        hash = hash,
        subject = subject,
        author = author,
        date = tonumber(date),
      })
    end
  end

  return result
end

--- Start watching git index
--- @param root string|nil Git root directory
--- @param callback function Callback on changes
--- @return boolean success
function M.watch(root, callback)
  root = root or M.root()
  if not root then
    return false
  end
  return watcher.start(root, callback)
end

--- Stop watching git index
--- @param root string|nil Git root directory
function M.unwatch(root)
  root = root or M.root()
  if root then
    watcher.stop(root)
  end
end

--- Clear root cache for buffer
--- @param bufnr number|nil Buffer number
function M.clear_cache(bufnr)
  if bufnr then
    root_cache[bufnr] = nil
  else
    root_cache = {}
  end
end

return M
