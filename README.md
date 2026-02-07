# Prism.nvim

**Claude Code + Neovim = 10-50x Token Savings**

Control Neovim with natural language. Edit files with vim commands instead of sending full file contents.

## Install (One Command)

In Claude Code, run:
```
/prism install
```

Or with curl:
```bash
curl -fsSL https://raw.githubusercontent.com/genomewalker/prism.nvim/main/install.sh | bash
```

That's it. Restart Claude Code and Neovim.

## What It Does

| Without Prism | With Prism |
|--------------|------------|
| Claude reads entire file (~1000 tokens) | Claude runs vim command (~20 tokens) |
| Claude sends full edit block (~800 tokens) | Claude runs `%s/old/new/g` (~15 tokens) |
| Multiple round trips | Direct editor control |

**Real savings**: A 500-line file edit goes from ~2000 tokens to ~30 tokens.

## Usage

1. **Press `Ctrl+;`** to toggle Claude terminal in Neovim
2. **Ask Claude anything**: "Replace all foo with bar in this file"
3. **Claude uses MCP tools** to control Neovim directly

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
| `<leader>cs` | Send selection/line to Claude |
| `<leader>cb` | Send entire buffer to Claude |
| `<leader>cf` | Send file path to Claude |
| `<leader>cd` | Send diagnostics to Claude |
| `<leader>cp` | Prompt Claude (input dialog) |
| `<leader>cc` | List files Claude changed |
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

## MCP Tools Available

When connected, Claude can use:

| Tool | Description |
|------|-------------|
| `mcp__prism-nvim__run_command` | Execute any vim command |
| `mcp__prism-nvim__open_file` | Open file in editor |
| `mcp__prism-nvim__get_buffer_content` | Read file content |
| `mcp__prism-nvim__save_file` | Save current file |
| `mcp__prism-nvim__search_in_file` | Regex search |
| `mcp__prism-nvim__get_diagnostics` | LSP diagnostics |

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

## How Token Savings Work

```
┌─────────────────────────────────────────┐
│              Without Prism              │
├─────────────────────────────────────────┤
│ Claude: Read("file.ts")                 │
│ → Returns 500 lines (~1500 tokens)      │
│                                         │
│ Claude: Edit("file.ts", old, new)       │
│ → Sends old block + new block           │
│ → (~800 tokens)                         │
│                                         │
│ Total: ~2300 tokens per edit            │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│               With Prism                │
├─────────────────────────────────────────┤
│ Claude: run_command("%s/old/new/g")     │
│ → 15 tokens                             │
│                                         │
│ Total: ~15-30 tokens per edit           │
│                                         │
│ Savings: 50-100x                        │
└─────────────────────────────────────────┘
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

**Sources**:
- [Claude Code Skills Documentation](https://docs.anthropic.com/en/docs/claude-code/slash-commands)
- [Claude Code MCP Integration](https://docs.anthropic.com/en/docs/claude-code/mcp)
