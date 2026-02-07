--- prism.nvim MCP Tool: getWorkspaceFolders
--- Gets information about workspace/project folders
--- @module prism.mcp.tools.get_workspace

local util = require("prism.util")

local M = {}

--- Tool definition
M.definition = {
  description = "Get information about workspace folders (git roots, cwd, and LSP workspaces)",
  inputSchema = {
    type = "object",
    properties = {
      includeLsp = {
        type = "boolean",
        description = "Include LSP workspace folders",
        default = true,
      },
    },
    required = {},
  },
  handler = function(params, _call_id)
    local include_lsp = params.includeLsp ~= false
    local folders = {}
    local seen = {}

    -- Current working directory
    local cwd = vim.fn.getcwd()
    if not seen[cwd] then
      seen[cwd] = true
      table.insert(folders, {
        uri = "file://" .. cwd,
        path = cwd,
        name = vim.fn.fnamemodify(cwd, ":t"),
        source = "cwd",
        isPrimary = true,
      })
    end

    -- Git root of current buffer
    local buf_path = vim.api.nvim_buf_get_name(0)
    if buf_path ~= "" then
      local git_root = util.git_root(buf_path)
      if git_root and not seen[git_root] then
        seen[git_root] = true
        table.insert(folders, {
          uri = "file://" .. git_root,
          path = git_root,
          name = vim.fn.fnamemodify(git_root, ":t"),
          source = "git",
          isPrimary = git_root == cwd,
        })
      end
    end

    -- Git roots of all open buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
        local path = vim.api.nvim_buf_get_name(buf)
        if path ~= "" then
          local root = util.git_root(path)
          if root and not seen[root] then
            seen[root] = true
            table.insert(folders, {
              uri = "file://" .. root,
              path = root,
              name = vim.fn.fnamemodify(root, ":t"),
              source = "git",
              isPrimary = false,
            })
          end
        end
      end
    end

    -- LSP workspace folders
    if include_lsp then
      local clients = vim.lsp.get_clients()
      for _, client in ipairs(clients) do
        local workspace_folders = client.workspace_folders or {}
        for _, folder in ipairs(workspace_folders) do
          local path = vim.uri_to_fname(folder.uri)
          if not seen[path] then
            seen[path] = true
            table.insert(folders, {
              uri = folder.uri,
              path = path,
              name = folder.name,
              source = "lsp",
              lspClient = client.name,
              isPrimary = false,
            })
          end
        end
      end
    end

    -- Detect project type for each folder
    for _, folder in ipairs(folders) do
      folder.projectType = M.detect_project_type(folder.path)
    end

    return {
      content = {
        {
          type = "text",
          text = util.json_encode({
            count = #folders,
            folders = folders,
          }),
        },
      },
      isError = false,
    }
  end,
}

--- Detect project type based on files present
--- @param path string Project path
--- @return table Project type info
function M.detect_project_type(path)
  local markers = {
    -- Lua/Neovim
    { file = "init.lua", type = "neovim-plugin" },
    { file = ".luarc.json", type = "lua" },
    { file = "stylua.toml", type = "lua" },

    -- JavaScript/TypeScript
    { file = "package.json", type = "node" },
    { file = "tsconfig.json", type = "typescript" },
    { file = "deno.json", type = "deno" },
    { file = "bun.lockb", type = "bun" },

    -- Python
    { file = "pyproject.toml", type = "python" },
    { file = "setup.py", type = "python" },
    { file = "requirements.txt", type = "python" },
    { file = "Pipfile", type = "python" },

    -- Rust
    { file = "Cargo.toml", type = "rust" },

    -- Go
    { file = "go.mod", type = "go" },

    -- Ruby
    { file = "Gemfile", type = "ruby" },

    -- Java/Kotlin
    { file = "pom.xml", type = "maven" },
    { file = "build.gradle", type = "gradle" },
    { file = "build.gradle.kts", type = "gradle-kotlin" },

    -- C/C++
    { file = "CMakeLists.txt", type = "cmake" },
    { file = "Makefile", type = "make" },
    { file = "meson.build", type = "meson" },

    -- .NET
    { file = "*.csproj", type = "dotnet", glob = true },
    { file = "*.sln", type = "dotnet", glob = true },

    -- Generic
    { file = ".git", type = "git" },
  }

  local detected = {}
  for _, marker in ipairs(markers) do
    local check_path = path .. "/" .. marker.file
    if marker.glob then
      local matches = vim.fn.glob(check_path, false, true)
      if #matches > 0 then
        table.insert(detected, marker.type)
      end
    else
      if vim.fn.filereadable(check_path) == 1 or vim.fn.isdirectory(check_path) == 1 then
        table.insert(detected, marker.type)
      end
    end
  end

  return {
    types = detected,
    primary = detected[1],
  }
end

--- Register this tool with the registry
--- @param registry table Tool registry
function M.register(registry)
  registry.register("getWorkspaceFolders", M.definition)
end

return M
