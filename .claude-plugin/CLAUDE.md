# prism-nvim Plugin Instructions

## MCP First

When connected to Neovim, **always prefer MCP tools** over standard Claude Code tools:

| Task | Use MCP | Not |
|------|---------|-----|
| Read file | `mcp__prism-nvim__get_buffer_content` | `Read` |
| Edit file | `mcp__prism-nvim__run_command("%s/old/new/g")` | `Edit` |
| Open file | `mcp__prism-nvim__open_file` | `Read` |
| Save file | `mcp__prism-nvim__save_file` | automatic |
| Search | `mcp__prism-nvim__search_in_file` | `Grep` |

## Why MCP?

- **10-50x token savings**: vim commands ~20 tokens vs file contents ~1000+ tokens
- **Direct control**: Changes appear instantly in editor
- **Protected terminal**: `run_command` auto-switches to editor window

## Check Connection

Before using MCP, verify:
```
mcp__prism-nvim__get_current_file
```

If this fails, fall back to standard tools.

## Common Vim Commands

```vim
%s/old/new/g              " Replace all in file
10,20s/old/new/g          " Replace in line range
1wincmd w | %s/x/y/g | w  " Switch to editor, replace, save
bufdo %s/foo/bar/g | w    " Replace across all buffers
```

## Window Management

- Terminal is protected from buffer-switching commands
- `run_command` auto-switches to editor window for `edit`, `buffer`, `split`
- Focus returns to terminal after command

## File Operations

```
mcp__prism-nvim__open_file(path="src/main.lua", line=42)
mcp__prism-nvim__run_command("1wincmd w | %s/old/new/g | w")
mcp__prism-nvim__save_file()
```
