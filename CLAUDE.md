# Prism.nvim - Claude Instructions

## MCP-First Editing (Token Optimization)

When working in this project (or any project with prism.nvim), **prefer MCP tools over standard Claude Code tools** when Neovim is connected.

### Priority Order

1. **MCP tools** (when connected) - minimal tokens
2. **Standard tools** (fallback) - when MCP unavailable

### Tool Mapping

| Task | Use This | Instead Of |
|------|----------|------------|
| Read file | `mcp__prism-nvim__get_buffer_content` | `Read` |
| Read lines | `mcp__prism-nvim__get_buffer_lines` | `Read` with offset/limit |
| Search in file | `mcp__prism-nvim__search_in_file` | `Grep` |
| Find/replace | `mcp__prism-nvim__run_command("%s/old/new/g")` | `Edit` |
| Edit lines | `mcp__prism-nvim__edit_buffer` | `Edit` |
| Write file | `mcp__prism-nvim__set_buffer_content` | `Write` |
| Save | `mcp__prism-nvim__save_file` | (automatic) |
| Open file | `mcp__prism-nvim__open_file` | `Read` |

### Vim Commands via run_command

Common patterns:
```vim
%s/old/new/g          " Replace all in file
10,20s/old/new/g      " Replace in line range
/pattern              " Search
:w                    " Save
:e path               " Open file
```

### Check MCP Connection

Before using MCP tools, verify connection:
```
mcp__prism-nvim__get_current_file
```

If this fails, fall back to standard tools.

### Benefits

- **Token savings**: vim commands are ~10-20 tokens vs hundreds/thousands for file contents
- **Speed**: Direct Neovim control, no file I/O overhead
- **Live editing**: Changes appear instantly in the editor

