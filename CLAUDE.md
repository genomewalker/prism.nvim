# Prism.nvim - Claude Code Instructions

## CRITICAL: Visible Editing Workflow

When Neovim is connected via prism.nvim MCP, the user is watching their editor. Every edit MUST be visible to them. Using Claude Code's built-in Read/Edit/Write tools makes changes behind the user's back -- they see nothing happen in their editor. This defeats the entire purpose of the integration.

**Rule: If MCP is connected, NEVER use Claude Code's Read, Edit, or Write tools for files. Always use MCP tools instead.**

### The Visible Editing Pattern

For every file edit, follow this sequence:

1. **Show the file**: `open_file` to display it in the editor
2. **Navigate to the location**: `goto_line` to jump to the relevant area
3. **Make the edit**: `edit_buffer`, `run_command`, or `search_and_replace`
4. **Save**: `save_file` to persist changes

The user watches each step happen live in their Neovim instance.

### Why This Matters

- The user chose prism.nvim to SEE Claude work in their editor
- Silent edits via Read/Edit/Write bypass the editor entirely
- The user cannot review, undo, or react to invisible changes
- MCP edits integrate with Neovim's undo tree (`u` to undo)

## MCP Connection Check

Before using any MCP tools, verify the connection:

```
mcp__prism-nvim__get_current_file
```

- If it succeeds: use MCP tools for all file operations
- If it fails: fall back to standard Claude Code tools (Read, Edit, Write)

Do this check once at the start of a session, not before every tool call.

## Tool Mapping: MCP vs Standard

| Task | MCP Tool (use when connected) | Standard Tool (fallback) |
|------|-------------------------------|--------------------------|
| Read a file | `open_file` + `get_buffer_content` | `Read` |
| Read specific lines | `get_buffer_lines` | `Read` with offset/limit |
| Edit a file (visible) | `open_file` -> `goto_line` -> `edit_buffer` | `Edit` |
| Find and replace | `search_and_replace` or `run_command("%s/old/new/g")` | `Edit` |
| Write new file | `create_file` | `Write` |
| Replace entire content | `set_buffer_content` | `Write` |
| Save file | `save_file` | (automatic) |
| Search in file | `search_in_file` | `Grep` |

## Token Savings

MCP tools use 10-50x fewer tokens than standard tools:

```
Standard Edit: ~800-2000 tokens (sends old block + new block + full context)
MCP run_command("%s/old/new/g"): ~15-30 tokens

Standard Read: ~500-1500 tokens (returns full file content)
MCP get_buffer_lines(start=10, end=20): ~50-100 tokens
```

## Editing Strategies

### Small, Targeted Edits (best for token savings)

Use `run_command` with vim substitution:

```
run_command("%s/oldFunction/newFunction/g")      -- Replace all in current file
run_command("10,20s/old/new/g")                  -- Replace in line range only
run_command("%s/console\\.log/logger.debug/g")   -- Escape dots in patterns
```

### Line-Range Edits

Use `edit_buffer` for replacing specific lines:

```
edit_buffer(start_line=15, end_line=20, new_lines=["  new line 1", "  new line 2"])
```

### Single Line Insertion

Use `insert_text` for inserting at a specific position:

```
insert_text(line=5, column=0, text="import { foo } from 'bar';\n")
```

### Whole-File Replacement

Use `set_buffer_content` when rewriting significant portions:

```
set_buffer_content(content="entire new file content here", path="src/file.ts")
```

## Vim Commands via run_command

The `run_command` tool executes Neovim ex commands. Common patterns:

```vim
%s/old/new/g              " Replace all occurrences in file
%s/old/new/gc             " Replace with confirmation
10,20s/old/new/g          " Replace in line range
g/pattern/d               " Delete all lines matching pattern
g!/pattern/d              " Delete all lines NOT matching pattern
:w                        " Save current file
:e!                       " Reload file from disk
normal! gg=G              " Re-indent entire file
```

### Terminal Window Protection

The `run_command` tool automatically handles window focus. It switches to the editor window before executing buffer-affecting commands, then returns focus to the terminal. You do not need to manually run `wincmd` commands in most cases.

## Available MCP Tools Reference

### File Operations
- `open_file(path, line?, column?)` -- Open file in editor area
- `save_file(path?)` -- Save current or specified file
- `close_file(path?, force?)` -- Close a buffer
- `create_file(path, content?)` -- Create new file with content

### Buffer Operations
- `get_buffer_content(path?)` -- Read entire file content
- `get_buffer_lines(path?, start_line?, end_line?)` -- Read specific lines
- `set_buffer_content(content, path?)` -- Replace entire buffer
- `edit_buffer(start_line, end_line, new_lines, path?)` -- Edit line range
- `insert_text(line, column, text, path?)` -- Insert at position

### Navigation
- `goto_line(line)` -- Jump to line number
- `goto_matching` -- Jump to matching bracket
- `next_error(severity?)` -- Jump to next diagnostic
- `prev_error(severity?)` -- Jump to previous diagnostic
- `jump_back(count?)` -- Jump list backward
- `jump_forward(count?)` -- Jump list forward
- `goto_bookmark(name)` -- Jump to named bookmark

### Search and Replace
- `search_in_file(pattern)` -- Search for pattern in current file
- `search_and_replace(pattern, replacement, flags?)` -- Replace in current file

### LSP Integration
- `get_diagnostics(path?)` -- Get errors/warnings
- `goto_definition` -- Go to symbol definition
- `get_hover_info` -- Get documentation for symbol
- `get_references` -- Find all references
- `rename_symbol(new_name)` -- Rename across files
- `code_actions(apply_first?)` -- Get/apply quick fixes
- `format_file` -- Format with LSP formatter

### Line Operations
- `comment(start_line?, end_line?)` -- Toggle comment
- `duplicate_line(line?, count?)` -- Duplicate line
- `move_line(direction, start_line?, end_line?)` -- Move line up/down
- `delete_line(start_line?, end_line?)` -- Delete lines
- `join_lines(count?)` -- Join lines together

### Indentation
- `indent(start_line?, end_line?, count?)` -- Increase indent
- `dedent(start_line?, end_line?, count?)` -- Decrease indent

### Selection
- `get_selection` -- Get currently selected text
- `select_word` -- Select word under cursor
- `select_line(start_line?, end_line?)` -- Select lines
- `select_block(type?, around?)` -- Select code block
- `select_all` -- Select entire buffer

### Undo/Redo
- `undo(count?)` -- Undo changes
- `redo(count?)` -- Redo changes

### Bookmarks
- `bookmark(name, description?)` -- Create bookmark
- `list_bookmarks` -- List all bookmarks
- `delete_bookmark(name)` -- Remove bookmark

### Editor State
- `get_current_file` -- Current file info (also used as connection check)
- `get_open_files` -- List all open buffers
- `get_cursor_position` -- Current cursor position
- `set_cursor_position(line, column)` -- Move cursor

### Window Management
- `split_window(vertical?, path?)` -- Create split
- `close_window(force?)` -- Close window
- `get_windows` -- All window info

### Git
- `git_status` -- Project git status
- `git_diff(staged?)` -- Git diff output

### Other
- `run_command(command)` -- Execute any Neovim ex command
- `notify(message, level?)` -- Show notification to user
- `diff_preview(path, new_content)` -- Show side-by-side diff
- `get_config` -- Get prism configuration
- `set_config(narrated?)` -- Update config (enable narrated mode to learn vim)
- `fold(line?, all?)` / `unfold(line?, all?)` -- Code folding
- `explain_command(command)` -- Explain a vim command
- `suggest_command(task)` -- Suggest vim command for a task
- `vim_cheatsheet(category?)` -- Show vim commands

## Narrated Mode (Learn Vim)

Enable narrated mode to see vim commands as they execute:

```
set_config(narrated=true)
```

Now every operation shows a notification like "Toggle comment (gcc)" teaching the vim way.
