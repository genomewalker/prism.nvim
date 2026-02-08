# prism.nvim

**Claude controls your editor directly. Talk to it. Watch it edit.**

55+ MCP tools with 10-50x token savings. No vim knowledge required.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9+-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Plugin-orange)](https://docs.anthropic.com/en/docs/claude-code)
[![Docs](https://img.shields.io/badge/Docs-Website-blue)](https://genomewalker.github.io/prism.nvim/)

---

## Vibe Coding

Don't know vim? No problem. Just talk:

```
"go to line 42"           → cursor jumps
"comment this"             → toggles comment
"replace foo with bar"     → done
"fix this error"           → applies LSP fix
"commit with message X"    → git commit
```

Watch every edit happen live in your editor. Full undo support.

## Install

Two commands. That's it:

```bash
/plugin add-marketplace genomewalker/prism.nvim
/plugin install prism-nvim@genomewalker-prism-nvim
```

Or use the skill: `/prism install`

Then restart Claude Code and open Neovim.

## Quick Start

1. Press **`Ctrl+;`** to toggle Claude terminal
2. Talk naturally: "replace foo with bar"
3. Watch it happen live

## Learn Vim as You Go

Say "teach me vim" to enable narrated mode. Every action shows the vim command:

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

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl+;` | Toggle Claude terminal |
| `Ctrl+\ Ctrl+\` | Exit terminal mode (passthrough) |
| `<leader>cs` | Send selection to Claude |

## Shell Aliases

```bash
nvc              # nvim + Claude
nvc -c           # continue last conversation
nvc --model opus # use Opus model
nvco             # shortcut for opus
```

## 55+ MCP Tools

**Editing:** comment, duplicate, move, delete, indent, fold, undo/redo

**Navigation:** goto_line, next_error, jump_back, bookmarks

**LSP:** diagnostics, fix_diagnostic, goto_definition, rename_symbol, format

**Git:** status, diff, stage, commit, blame, log

**Learning:** explain_command, suggest_command, vim_cheatsheet

## Configuration

```lua
require("prism").setup({
  terminal = { width = 0.4, passthrough = true },
  trust = { mode = "companion" },  -- guardian | companion | autopilot
})
```

## Requirements

- Neovim 0.9+
- Claude Code CLI
- Python 3.10+ with msgpack

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP not connecting | Restart Claude Code, run `/prism status` |
| Terminal disappears | Press `Ctrl+;` |
| Stuck in terminal | `Ctrl+\ Ctrl+\` exits to normal mode |

## License

MIT

---

*Built for developers who want Claude to actually control their editor.*

[Website](https://genomewalker.github.io/prism.nvim/) · [GitHub](https://github.com/genomewalker/prism.nvim) · [Issues](https://github.com/genomewalker/prism.nvim/issues)
