# prism.nvim

**Claude controls your editor directly. Talk to it. Watch it edit.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9+-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Plugin-orange)](https://docs.anthropic.com/en/docs/claude-code)
[![Docs](https://img.shields.io/badge/Docs-Website-blue)](https://genomewalker.github.io/prism.nvim/)
[![Version](https://img.shields.io/github/v/release/genomewalker/prism.nvim?label=version)](https://github.com/genomewalker/prism.nvim/releases)

---

## Why Prism?

**See every edit happen.** Claude opens files, jumps to lines, and makes changes right in front of you. Full undo support - just press `u`.

**Save 10-50x tokens.** Vim commands are tiny (`%s/old/new/g` = 15 tokens) vs Claude's Edit tool (~2000 tokens). Your context window lasts longer.

**No vim required.** Just talk: "go to line 42", "fix this error", "commit with message X". Prism translates.

---

## Install

```bash
/plugin add-marketplace genomewalker/prism.nvim
/plugin install prism-nvim@genomewalker-prism-nvim
```

Or: `/prism install`

Then **restart Claude Code** and open Neovim.

---

## Quick Start

```
Ctrl+;              → Toggle Claude terminal
"replace foo bar"   → Find and replace
"fix this error"    → Apply LSP quick fix
"commit changes"    → Git commit
Ctrl+\ Ctrl+\       → Exit to normal mode
```

---

## Vibe Coding

Don't know vim? Just describe what you want:

| You say | What happens |
|---------|--------------|
| "go to line 42" | Cursor jumps |
| "comment this" | Toggles comment |
| "duplicate line" | Line duplicated |
| "move this up" | Line moves up |
| "show errors" | Diagnostics panel |
| "rename to newName" | LSP rename |

### Learn Vim Along the Way

Say **"teach me vim"** to enable narrated mode:

```
📚 Toggle comment (gcc)
📚 Indent line (>>)  
📚 Jump to line (:50)
```

---

## Trust Modes

| Mode | What it does | Say this |
|------|--------------|----------|
| **Guardian** | Review every edit before applying | "be more careful" |
| **Companion** | Auto-apply with visual feedback | "I trust you" |
| **Autopilot** | Full speed, minimal UI | "just do it" |

---

## Git Integration

```
"what changed?"      → git status
"show diff"          → git diff  
"stage this"         → git add
"commit: fix bug"    → git commit -m "fix bug"
"who wrote this?"    → git blame
```

---

## Shell Aliases

After install, use `nvc` to launch:

```bash
nvc                  # nvim + Claude
nvc -c               # continue last session
nvc --model opus     # use Opus
nvco                 # shortcut for opus
```

---

## 55+ MCP Tools

| Category | Tools |
|----------|-------|
| **Editing** | comment, duplicate, move, delete, indent, fold, undo/redo |
| **Navigation** | goto_line, next_error, jump_back, bookmarks |
| **LSP** | diagnostics, fix_diagnostic, goto_definition, rename_symbol |
| **Git** | status, diff, stage, commit, blame, log |
| **Learning** | explain_command, suggest_command, vim_cheatsheet |

---

## Configuration

```lua
require("prism").setup({
  terminal = { width = 0.4, passthrough = true },
  trust = { mode = "companion" },
})
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| MCP not connecting | Restart Claude Code, run `/prism status` |
| Terminal gone | `Ctrl+;` brings it back |
| Stuck in terminal | `Ctrl+\ Ctrl+\` exits to normal mode |

---

## Requirements

- Neovim 0.9+
- Claude Code CLI  
- Python 3.10+ with msgpack

---

MIT · [Website](https://genomewalker.github.io/prism.nvim/) · [GitHub](https://github.com/genomewalker/prism.nvim) · [Issues](https://github.com/genomewalker/prism.nvim/issues)

