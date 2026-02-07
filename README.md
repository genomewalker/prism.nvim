# prism.nvim

**Claude controls your editor directly. Talk to it. Watch it edit.**

55+ MCP tools with 10-50x token savings. No vim knowledge required.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9+-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Plugin-orange)](https://docs.anthropic.com/en/docs/claude-code)
[![Docs](https://img.shields.io/badge/Docs-Website-blue)](https://genomewalker.github.io/prism.nvim/)

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

**Option 1: Claude Code Plugin** (Recommended)

```bash
# Add marketplace (one-time)
/plugin add-marketplace genomewalker/prism.nvim

# Install plugin
/plugin install prism-nvim@genomewalker-prism-nvim
```

**Option 2: Claude Code Skill**

```
/prism install
```

**Option 3: Curl**
```bash
curl -fsSL https://raw.githubusercontent.com/genomewalker/prism.nvim/main/install.sh | bash
```

Then restart Claude Code and Neovim.

## Quick Start

1. **Open Neovim**
2. **Press `Ctrl+;`** to toggle Claude terminal
3. **Talk naturally**: "Replace all foo with bar in this file"
4. **Watch Claude edit** your file in real-time

## Vibe Coding

Don't know vim? No problem. Just describe what you want:

| You say | Claude does |
|---------|-------------|
| "go to line 42" | Jumps to line 42 |
| "comment this line" | Toggles comment |
| "duplicate this" | Duplicates the line |
| "move this up" | Moves line up |
| "delete lines 10-20" | Deletes the range |
| "show me errors" | Shows diagnostics |
| "fix this error" | Applies quick fix |
| "replace foo with bar" | Find and replace |

### Learn Vim as You Go

Enable narrated mode to see vim commands as Claude executes them:

```
"teach me vim"
```

Now every action shows the equivalent vim command:
```
📚 Toggle comment (gcc)
📚 Indent line (>>)
📚 Jump to line 50 (:50)
```

## Trust Modes

Control how Claude handles edits:

| Mode | Description | Trigger |
|------|-------------|---------|
| **Guardian** | Review every edit | "be more careful" |
| **Companion** | Auto-accept with overlay | "I trust you" |
| **Autopilot** | Full auto, minimal UI | "just do it" |

Switch modes anytime by just telling Claude, or use `:PrismMode`.

## Git Operations

| You say | Claude does |
|---------|-------------|
| "what's changed?" | Shows git status |
| "show the diff" | Shows git diff |
| "stage this file" | Stages current file |
| "commit with message X" | Creates commit |
| "who wrote this?" | Shows git blame |
| "show recent commits" | Shows git log |

## Visible Editing

Watch every edit happen live:
- Files open in your editor
- Cursor jumps to the line
- Changes appear in real-time
- Full undo support (`u` to undo)

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl+;` | Toggle Claude terminal |
| `Ctrl+\ Ctrl+\` | Exit terminal mode |
| `<leader>cs` | Send selection to Claude |
| `<leader>cb` | Send buffer to Claude |
| `<leader>cd` | Send diagnostics to Claude |

## Commands

| Command | Action |
|---------|--------|
| `:Claude` | Toggle terminal |
| `:Claude --continue` | Continue last session |
| `:ClaudeSend [text]` | Send text or context |
| `:PrismMode` | Pick trust mode |

## Shell Commands

After install, you get `nvc` - nvim with Claude flags:

```bash
nvc                    # Just nvim + Claude
nvc -c                 # Continue last conversation
nvc --model opus       # Use Opus model
nvco                   # Shortcut for opus
```

## MCP Tools (55+)

### Editing
`comment` · `duplicate_line` · `move_line` · `delete_line` · `join_lines` · `indent` · `dedent` · `fold` · `unfold` · `undo` · `redo`

### Navigation
`goto_line` · `next_error` · `prev_error` · `jump_back` · `jump_forward` · `bookmark` · `goto_bookmark`

### Selection
`select_word` · `select_line` · `select_block` · `select_all` · `get_selection`

### LSP
`get_diagnostics` · `fix_diagnostic` · `goto_definition` · `get_references` · `rename_symbol` · `code_actions` · `format_file`

### Git
`git_status` · `git_diff` · `git_stage` · `git_commit` · `git_blame` · `git_log`

### Vim Learning
`explain_command` · `suggest_command` · `vim_cheatsheet`

## Configuration

```lua
require("prism").setup({
  terminal = {
    width = 0.4,           -- 40% of screen
    passthrough = true,    -- Real terminal feel
  },
  trust = {
    mode = "companion",    -- guardian | companion | autopilot
  },
})
```

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
│  │      Prism MCP Server (Python)        │   │
│  └───────────────────────────────────────┘   │
│                     │                        │
└─────────────────────│────────────────────────┘
                      │ lockfile discovery
                      ▼
            ┌──────────────────┐
            │   Claude Code    │
            └──────────────────┘
```

## Requirements

- Neovim >= 0.9.0
- Claude Code CLI
- Python 3.10+ with msgpack

## Troubleshooting

**MCP not connecting?**
1. Check `~/.claude/settings.json` has prism-nvim entry
2. Restart Claude Code
3. Run `/prism status` to check

**Terminal disappears?**
- Press `Ctrl+;` to bring it back

**Passthrough mode issues?**
- `Ctrl+\ Ctrl+\` exits to normal mode
- All other keys go to Claude

## License

MIT

---

*Built for developers who want Claude to actually control their editor.*

[Website](https://genomewalker.github.io/prism.nvim/) · [GitHub](https://github.com/genomewalker/prism.nvim) · [Issues](https://github.com/genomewalker/prism.nvim/issues)
