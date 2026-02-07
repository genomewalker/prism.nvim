--- prism.nvim MCP Tool: Global Search and Replace
--- Allows Claude to replace text across all matching files
--- @module prism.mcp.tools.search_replace_global

local M = {}

--- Register the tool with the MCP registry
--- @param registry table Tool registry
function M.register(registry)
  registry.register("search_replace_global", {
    description = "Search and replace text across all files in the project. Use for refactoring, renaming, or bulk text changes.",
    inputSchema = {
      type = "object",
      properties = {
        search = {
          type = "string",
          description = "Text or pattern to search for",
        },
        replace = {
          type = "string",
          description = "Replacement text",
        },
        glob = {
          type = "string",
          description = "File pattern to match (e.g., '**/*.lua', 'src/**/*.ts'). Default: all files",
          default = "**/*",
        },
        use_regex = {
          type = "boolean",
          description = "Treat search as regex pattern. Default: false (literal)",
          default = false,
        },
        confirm = {
          type = "boolean",
          description = "Show preview and ask user to confirm before applying. Default: true",
          default = true,
        },
      },
      required = { "search", "replace" },
    },
    handler = function(params, call_id)
      local search = params.search
      local replace = params.replace
      local glob = params.glob or "**/*"
      local use_regex = params.use_regex or false
      local confirm = params.confirm ~= false

      -- Find matching files
      local cwd = vim.fn.getcwd()
      local files = vim.fn.glob(cwd .. "/" .. glob, false, true)

      -- Filter to only readable files (not directories)
      local readable_files = {}
      for _, file in ipairs(files) do
        if vim.fn.filereadable(file) == 1 and vim.fn.isdirectory(file) == 0 then
          table.insert(readable_files, file)
        end
      end

      local matches = {}
      local total_count = 0

      -- Search each file
      for _, file in ipairs(readable_files) do
        local lines = vim.fn.readfile(file)
        local file_matches = {}

        for i, line in ipairs(lines) do
          local match_start, match_end
          if use_regex then
            match_start, match_end = string.find(line, search)
          else
            match_start, match_end = string.find(line, search, 1, true)
          end

          if match_start then
            table.insert(file_matches, {
              line = i,
              text = line,
              match = string.sub(line, match_start, match_end),
            })
            total_count = total_count + 1
          end
        end

        if #file_matches > 0 then
          local rel_path = vim.fn.fnamemodify(file, ":~:.")
          matches[rel_path] = file_matches
        end
      end

      if total_count == 0 then
        return {
          content = { { type = "text", text = "No matches found for: " .. search } },
          isError = false,
        }
      end

      -- Build preview
      local preview_lines = { "Found " .. total_count .. " matches in " .. vim.tbl_count(matches) .. " files:" }
      for file, file_matches in pairs(matches) do
        table.insert(preview_lines, "\n" .. file .. ":")
        for _, m in ipairs(file_matches) do
          local preview = "  L" .. m.line .. ": " .. m.text:gsub("^%s+", ""):sub(1, 60)
          table.insert(preview_lines, preview)
        end
      end

      if confirm then
        -- Show preview and ask for confirmation
        vim.schedule(function()
          local choice = vim.fn.confirm(
            table.concat(preview_lines, "\n") .. "\n\nReplace all with: " .. replace .. "?",
            "&Yes\n&No",
            2
          )

          if choice == 1 then
            -- Apply replacements
            local replaced_count = 0
            for file, _ in pairs(matches) do
              local full_path = vim.fn.fnamemodify(file, ":p")
              local lines = vim.fn.readfile(full_path)
              local modified = false

              for i, line in ipairs(lines) do
                local new_line
                if use_regex then
                  new_line = string.gsub(line, search, replace)
                else
                  new_line = string.gsub(line, vim.pesc(search), replace)
                end
                if new_line ~= line then
                  lines[i] = new_line
                  modified = true
                  replaced_count = replaced_count + 1
                end
              end

              if modified then
                vim.fn.writefile(lines, full_path)
                -- Reload buffer if open
                local bufnr = vim.fn.bufnr(full_path)
                if bufnr ~= -1 then
                  vim.api.nvim_buf_call(bufnr, function()
                    vim.cmd("edit!")
                  end)
                end
              end
            end

            vim.notify(
              "Replaced " .. replaced_count .. " occurrences in " .. vim.tbl_count(matches) .. " files",
              vim.log.levels.INFO
            )
          else
            vim.notify("Search and replace cancelled", vim.log.levels.INFO)
          end
        end)

        return {
          content = { { type = "text", text = table.concat(preview_lines, "\n") .. "\n\n(Waiting for user confirmation...)" } },
          isError = false,
        }
      else
        -- Apply immediately without confirmation
        local replaced_count = 0
        for file, _ in pairs(matches) do
          local full_path = vim.fn.fnamemodify(file, ":p")
          local lines = vim.fn.readfile(full_path)
          local modified = false

          for i, line in ipairs(lines) do
            local new_line
            if use_regex then
              new_line = string.gsub(line, search, replace)
            else
              new_line = string.gsub(line, vim.pesc(search), replace)
            end
            if new_line ~= line then
              lines[i] = new_line
              modified = true
              replaced_count = replaced_count + 1
            end
          end

          if modified then
            vim.fn.writefile(lines, full_path)
            -- Reload buffer if open
            local bufnr = vim.fn.bufnr(full_path)
            if bufnr ~= -1 then
              vim.schedule(function()
                vim.api.nvim_buf_call(bufnr, function()
                  vim.cmd("edit!")
                end)
              end)
            end
          end
        end

        return {
          content = { { type = "text", text = "Replaced " .. replaced_count .. " occurrences of '" .. search .. "' with '" .. replace .. "' in " .. vim.tbl_count(matches) .. " files" } },
          isError = false,
        }
      end
    end,
  })
end

return M
