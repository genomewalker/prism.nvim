# prism.nvim

**Claude Code + Neovim = 10-50x Token Savings**

Control Neovim with natural language. Edit files with vim commands instead of sending full file contents.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9+-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Plugin-orange)](https://docs.anthropic.com/en/docs/claude-code)
[![Docs](https://img.shields.io/badge/Docs-Website-blue)](https://kbd606.github.io/prism.nvim/)

---

## Why Prism?

```
┌─────────────────────────────────────────┐
│            Without Prism                │
├─────────────────────────────────────────┤
│ Claude: Read("file.ts")                 │
│ → Returns 500 lines (~1,500 tokens)     │
│                                         │
│ Claude: Edit("file.ts", old, new)       │
│ → Sends old block + new block           │
│ → (~800 tokens)                         │
│                                         │
│ Total: ~2,300 tokens per edit           │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│              With Prism                 │
├─────────────────────────────────────────┤
│ Claude: run_command("%s/old/new/g")     │
│ → 15 tokens                             │
│                                         │
│ Total: ~15-30 tokens per edit           │
│                                         │
│ Savings: 50-100x                        │
└─────────────────────────────────────────┘
```

## Install

**Option 1: Claude Code Skill** (Recommended)

In Claude Code, run:
```
/prism install
```

**Option 2: Curl**
```bash
curl -fsSL https://raw.githubusercontent.com/genomewalker/prism.nvim/main/install.sh | bash
```

Then restart Claude Code and Neovim.

## Quick Start

1. **Open Neovim**
2. **Press `Ctrl+;`** to toggle Claude terminal
3. **Ask Claude anything**: "Replace all foo with bar in this file"
4. **Claude uses MCP tools** to control Neovim directly

### Example Conversation

```
You: Replace console.log with logger.debug across all TypeScript files

Claude: I'll use the MCP tools to do this efficiently.
[runs: mcp__prism-nvim__run_command("bufdo %s/console.log/logger.debug/g | w")]
Done. Replaced in 12 files.
```

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl+;` | Toggle Claude terminal |
| `Ctrl+\ Ctrl+\` | Exit terminal mode (passthrough) |
| `Ctrl+Right-click` | Context menu (copy, paste, etc) |
| `<leader>cs` | Send selection/line to Claude |
| `<leader>cb` | Send entire buffer to Claude |
| `<leader>cf` | Send file path to Claude |
| `<leader>cd` | Send diagnostics to Claude |
| `<leader>cp` | Prompt Claude (input dialog) |
| `]g` | Jump to next file Claude changed |

## Commands

| Command | Action |
|---------|--------|
| `:Claude` | Toggle terminal |
| `:Claude --continue` | Continue last conversation |
| `:ClaudeSend [text]` | Send text or context |
| `:ClaudeBuffer` | Send entire buffer |
| `:ClaudeDiag` | Send LSP diagnostics |
| `:ClaudeNav` | Pick from changed files |
| `:ClaudeClear` | Clear changed files list |

## MCP Tools (40+)

Prism gives Claude direct control of Neovim. No vim knowledge required.

### Vibe Coder Essentials

| Tool | What You Say |
|------|--------------|
| `comment` | "Comment this line" |
| `duplicate_line` | "Duplicate this" |
| `move_line` | "Move this up" |
| `delete_line` | "Delete lines 10-20" |
| `indent` / `dedent` | "Indent this block" |
| `fold` / `unfold` | "Collapse this function" |
| `undo` / `redo` | "Undo that" |

### Navigation

| Tool | What You Say |
|------|--------------|
| `goto_line` | "Go to line 50" |
| `next_error` | "Jump to next error" |
| `jump_back` | "Go back" |
| `bookmark` | "Remember this spot" |

### Learn Vim Mode

Enable narrated mode to see vim commands as Claude executes them:

```
set_config narrated=true
```

Now every action shows the equivalent vim command:
```
📚 Toggle comment (gcc)
📚 Indent line (>>)
📚 Jump to line 50 (:50)
```

### Ask About Vim

| Tool | Example |
|------|---------|
| `explain_command` | "What does ciw do?" |
| `suggest_command` | "How do I delete inside quotes?" |
| `vim_cheatsheet` | "Show me editing commands" |

### Token-Saving Patterns

## Configuration

```lua
require("prism.core").setup({
  toggle_key = "<C-;>",      -- Toggle Claude terminal
  terminal_width = 0.4,      -- 40% of screen
  auto_reload = true,        -- Reload when Claude edits files
  mcp = true,                -- Enable MCP server
  passthrough = true,        -- Real terminal feel
})
```

## Shell Function

After install, you get `nvc` - nvim with Claude flags:

```bash
nvc                          # Just nvim + Claude
nvc -c                       # Continue last conversation (short for --continue)
nvc --model opus             # Use Opus model
nvc -c --model opus          # Continue with Opus
nvc --dangerously-skip-permissions  # Skip permission prompts
nvc myfile.lua               # Open file
nvc -c src/                  # Continue, open directory
```

Flags starting with `-` go to Claude, everything else goes to nvim.

## Architecture

```
┌──────────────────────────────────────────────┐
│                   Neovim                     │
│  ┌─────────────┐      ┌───────────────────┐  │
│  │   Editor    │      │  Claude Terminal  │  │
│  │   Window    │◄────►│   (Ctrl+;)        │  │
│  └─────────────┘      └───────────────────┘  │
│         │                                    │
│         ▼                                    │
│  ┌───────────────────────────────────────┐   │
│  │      Prism MCP Server (WebSocket)     │   │
│  │  run_command, open_file, save, etc.   │   │
│  └───────────────────────────────────────┘   │
│                     │                        │
└─────────────────────│────────────────────────┘
                      │ lockfile discovery
                      ▼
            ┌──────────────────┐
            │   Claude Code    │
            │   (MCP client)   │
            └──────────────────┘
```

### How It Works

1. **Neovim** runs an MCP server on a WebSocket port
2. **Lockfile** at `~/.claude/ide/[port].lock` advertises the connection
3. **Claude Code** discovers the lockfile and connects via MCP
4. **Claude** uses MCP tools to run vim commands directly
5. **Token savings** come from sending ~20 token commands vs ~2000 token file contents

## Requirements

- Neovim >= 0.9.0
- Claude Code CLI
- Python 3.10+ with msgpack

## Troubleshooting

**MCP not connecting?**
1. Check `~/.claude/settings.json` has prism-nvim entry
2. Restart Claude Code
3. In Neovim: `:lua require('prism.mcp').status()`

**Terminal disappears?**
- Press `Ctrl+;` to bring it back
- The terminal window is protected from vim commands

**Passthrough mode issues?**
- `Ctrl+\ Ctrl+\` exits to normal mode
- All other keys (including Escape) go to Claude

## License

MIT

---

*Built for developers who want Claude to actually control their editor.*

**Links**:
- [Documentation Website](https://kbd606.github.io/prism.nvim/)
- [Claude Code Skills](https://docs.anthropic.com/en/docs/claude-code/slash-commands)
- [Claude Code MCP](https://docs.anthropic.com/en/docs/claude-code/mcp)
