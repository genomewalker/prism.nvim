---
name: prism
description: Install and configure prism.nvim - Neovim integration with token-saving MCP tools. Use when user wants to set up Neovim integration, control Neovim from Claude, or save tokens with MCP editing.
argument-hint: "[install|status|help]"
allowed-tools: Bash(git *), Bash(python* *), Bash(pip *), Bash(mkdir *), Bash(ln *), Bash(cat *), Read, Write, Edit
---

# Prism.nvim - Claude Code + Neovim Integration

You are installing prism.nvim, which lets Claude control Neovim via MCP tools for 10-50x token savings.

## Handle Arguments

Based on `$ARGUMENTS`:

- **install** (or no args): Run full installation
- **status**: Check if prism is installed and MCP connected
- **help**: Show usage information

## Installation Steps

### Step 1: Clone Repository

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
if [ -d "$PRISM_DIR" ]; then
  cd "$PRISM_DIR" && git pull
else
  git clone https://github.com/genomewalker/prism.nvim.git "$PRISM_DIR"
fi
```

### Step 2: Install Python Dependencies

```bash
python3 -m pip install --user msgpack
```

### Step 3: Link Neovim Plugin

```bash
PACK_DIR="$HOME/.local/share/nvim/site/pack/prism/start"
mkdir -p "$PACK_DIR"
ln -sf "$HOME/.local/share/prism.nvim" "$PACK_DIR/prism.nvim"
```

### Step 4: Register MCP Server

Add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "prism-nvim": {
      "type": "stdio",
      "command": "python3",
      "args": ["-m", "prism_nvim.mcp_server"],
      "cwd": "~/.local/share/prism.nvim"
    }
  }
}
```

Use the Edit tool to merge this into existing settings.json, preserving other mcpServers.

### Step 5: Create Neovim Config

Create `~/.config/nvim/lua/plugins/prism.lua`:

```lua
return {
  dir = vim.fn.expand("~/.local/share/prism.nvim"),
  lazy = false,
  config = function()
    require("prism.core").setup({
      toggle_key = "<C-;>",
      terminal_width = 0.4,
      auto_reload = true,
      mcp = true,
      passthrough = true,
    })
  end,
}
```

### Step 6: Add Claude Instructions

Append to `~/.claude/CLAUDE.md` (create if needed):

```markdown
# Prism.nvim MCP Integration

When connected to Neovim via prism.nvim, **prefer MCP tools over standard tools**:

| Task | MCP Tool | Saves |
|------|----------|-------|
| Read file | `mcp__prism-nvim__get_buffer_content` | 10-50x |
| Edit file | `mcp__prism-nvim__run_command("%s/old/new/g")` | 20-30x |
| Open file | `mcp__prism-nvim__open_file` | 5x |

Check connection: `mcp__prism-nvim__get_current_file`
```

### Step 7: Add Shell Aliases

Append to `~/.zshrc` or `~/.bashrc`:

```bash
# Prism.nvim helpers
alias nvc='CLAUDE_ARGS="--continue" nvim'
alias nvco='CLAUDE_ARGS="--model opus" nvim'
```

## After Installation

Tell the user:

1. **Restart Claude Code** to load the MCP server
2. **Open Neovim** and run `:lua require('prism.core').setup()`
3. **Press Ctrl+;** to toggle Claude terminal
4. **Use Ctrl+\ Ctrl+\** to exit terminal mode

## Status Check

To check status:
1. Try `mcp__prism-nvim__get_current_file` - if it works, MCP is connected
2. Check `~/.claude/settings.json` for prism-nvim entry
3. Check Neovim has prism loaded: `:lua print(require('prism.core'))`

## Token Savings

Explain that MCP tools save tokens because:
- Vim commands are ~20 tokens (e.g., `%s/old/new/g`)
- Standard Edit tool sends full file content (~500-2000 tokens)
- For a 500-line file, that's **25-100x savings per edit**
