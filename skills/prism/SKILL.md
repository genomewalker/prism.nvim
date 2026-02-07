---
name: prism
description: Install and configure prism.nvim - Neovim integration with token-saving MCP tools
argument-hint: "[install|status|help]"
execution: direct
---

# Prism.nvim - Claude Code + Neovim Integration

You are installing prism.nvim, which lets Claude control Neovim via MCP tools for 10-50x token savings.

## Handle Arguments

Based on `$ARGUMENTS`:

- **install** (or no args): Run full installation
- **status**: Check if prism is installed and MCP connected
- **help**: Show usage information

## Installation Steps (Idempotent)

All steps check if already done before making changes.

### Step 1: Clone or Update Repository

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
if [ -d "$PRISM_DIR" ]; then
  cd "$PRISM_DIR"
  # Check current version
  LOCAL_VERSION=$(grep '^version' pyproject.toml 2>/dev/null | cut -d'"' -f2)
  echo "Current version: $LOCAL_VERSION"

  # Fetch and check for updates
  git fetch origin main --quiet
  BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")

  if [ "$BEHIND" -gt 0 ]; then
    echo "Updates available ($BEHIND commits behind)"
    git pull
    NEW_VERSION=$(grep '^version' pyproject.toml | cut -d'"' -f2)
    echo "Updated to version: $NEW_VERSION"
  else
    echo "Already up to date"
  fi
else
  git clone https://github.com/genomewalker/prism.nvim.git "$PRISM_DIR"
  cd "$PRISM_DIR"
  VERSION=$(grep '^version' pyproject.toml | cut -d'"' -f2)
  echo "Installed version: $VERSION"
fi
```

### Step 2: Install Python Dependencies

```bash
python3 -c "import msgpack" 2>/dev/null && echo "msgpack already installed" || python3 -m pip install --user msgpack
```

### Step 3: Link Neovim Plugin

```bash
PACK_DIR="$HOME/.local/share/nvim/site/pack/prism/start"
if [ -L "$PACK_DIR/prism.nvim" ]; then
  echo "Neovim plugin already linked"
else
  mkdir -p "$PACK_DIR"
  ln -sf "$HOME/.local/share/prism.nvim" "$PACK_DIR/prism.nvim"
fi
```

### Step 4: Register MCP Server

**First check** if prism-nvim already exists in `~/.claude/settings.json`:

```bash
grep -q '"prism-nvim"' ~/.claude/settings.json && echo "MCP already configured"
```

**Only if not configured**, use Edit tool to add to mcpServers:

```json
"prism-nvim": {
  "type": "stdio",
  "command": "python3",
  "args": ["-m", "prism_nvim.mcp_server"],
  "cwd": "~/.local/share/prism.nvim"
}
```

### Step 5: Create Neovim Config

**Check if exists** first: `~/.config/nvim/lua/plugins/prism.lua`

If file exists, skip. Otherwise create:

```lua
-- Prism.nvim - Claude Code Integration
return {
  {
    dir = vim.fn.expand("~/.local/share/prism.nvim"),
    name = "prism.nvim",
    lazy = false,
    dependencies = {
      "MunifTanjim/nui.nvim",
    },
    config = function()
      require("prism").setup({
        -- MCP server is handled by Python, disable Lua server
        mcp = {
          auto_start = false,
        },
        -- Terminal settings
        terminal = {
          provider = "native",
          position = "vertical",
          width = 0.4,
          auto_start = false,  -- Set true to auto-open Claude terminal
          passthrough = true,  -- Real terminal: only Ctrl+\ Ctrl+\ escapes
        },
        -- Claude flags (set via nvc command or CLAUDE_ARGS env)
        claude = {
          model = nil,
          continue_session = false,
        },
        -- Trust mode for edits
        trust = {
          mode = "companion",  -- "guardian" | "companion" | "autopilot"
        },
      })
    end,
    keys = {
      { "<leader>cc", "<cmd>Prism<cr>", desc = "Prism: Open Layout" },
      { "<leader>ct", "<cmd>PrismToggle<cr>", desc = "Prism: Toggle Terminal" },
      { "<leader>cs", "<cmd>PrismSend<cr>", mode = { "n", "v" }, desc = "Prism: Send to Claude" },
      { "<leader>ca", "<cmd>PrismAction<cr>", mode = { "n", "v" }, desc = "Prism: Code Actions" },
      { "<leader>cd", "<cmd>PrismDiff<cr>", desc = "Prism: Show Diff" },
      { "<leader>cm", "<cmd>PrismModel<cr>", desc = "Prism: Switch Model" },
      { "<C-\\>", "<cmd>PrismToggle<cr>", desc = "Toggle Prism Terminal" },
    },
  },
}
```

### Step 6: Link Claude Instructions

**Check first**:
```bash
[ -L ~/.claude/rules/prism-nvim.md ] && echo "Rules already linked"
```

**Only if not linked**:
```bash
mkdir -p ~/.claude/rules
ln -sf ~/.local/share/prism.nvim/CLAUDE.md ~/.claude/rules/prism-nvim.md
```

This auto-loads prism instructions in every Claude session. Optionally also append to `~/.claude/CLAUDE.md`:

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

Use AskUserQuestion to ask which shell the user uses:

```
question: "Which shell do you use?"
header: "Shell"
options:
  - label: "Bash"
    description: "Add aliases to ~/.bashrc"
  - label: "Zsh"
    description: "Add aliases to ~/.zshrc"
  - label: "Fish"
    description: "Add functions to ~/.config/fish/functions/"
```

**Check if nvc already exists** before adding:
```bash
grep -q "nvc()" ~/.bashrc 2>/dev/null && echo "nvc already in bashrc"
grep -q "nvc()" ~/.zshrc 2>/dev/null && echo "nvc already in zshrc"
```

Only append if not already present:

**For Bash/Zsh** (`~/.bashrc` or `~/.zshrc`):

```bash
# Prism.nvim helpers
nvc() {
  local claude_args=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model|--continue|--resume|-c|-r)
        if [[ "$1" == "--model" ]]; then
          claude_args="$claude_args $1 $2"
          shift 2
        else
          claude_args="$claude_args $1"
          shift
        fi
        ;;
      *)
        break
        ;;
    esac
  done
  CLAUDE_ARGS="$claude_args" nvim "$@"
}
alias nvco='nvc --model opus'
```

**For Fish** (`~/.config/fish/functions/nvc.fish`):

```fish
function nvc
    set -l claude_args ""
    while test (count $argv) -gt 0
        switch $argv[1]
            case --model
                set claude_args "$claude_args $argv[1] $argv[2]"
                set argv $argv[3..-1]
            case --continue --resume -c -r
                set claude_args "$claude_args $argv[1]"
                set argv $argv[2..-1]
            case '*'
                break
        end
    end
    CLAUDE_ARGS="$claude_args" nvim $argv
end
```

## After Installation

Tell the user:

1. **Restart Claude Code** to load the MCP server
2. **Open Neovim** and run `:lua require('prism.core').setup()`
3. **Press Ctrl+;** to toggle Claude terminal
4. **Use Ctrl+\ Ctrl+\** to exit terminal mode

## Status Check

Run these checks and report results:

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
if [ -d "$PRISM_DIR" ]; then
  cd "$PRISM_DIR"
  LOCAL_VERSION=$(grep '^version' pyproject.toml 2>/dev/null | cut -d'"' -f2)
  git fetch origin main --quiet 2>/dev/null
  BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "?")
  echo "Version: $LOCAL_VERSION (${BEHIND} commits behind)"
else
  echo "Not installed"
fi
```

Also check:
1. **MCP connection**: Try `mcp__prism-nvim__get_current_file` - if it works, MCP is connected
2. **Settings**: `grep -q '"prism-nvim"' ~/.claude/settings.json && echo "MCP configured"`
3. **Neovim plugin**: `[ -L ~/.local/share/nvim/site/pack/prism/start/prism.nvim ] && echo "Plugin linked"`
4. **Rules linked**: `[ -L ~/.claude/rules/prism-nvim.md ] && echo "Rules linked"`

## Token Savings

Explain that MCP tools save tokens because:
- Vim commands are ~20 tokens (e.g., `%s/old/new/g`)
- Standard Edit tool sends full file content (~500-2000 tokens)
- For a 500-line file, that's **25-100x savings per edit**

## Natural Language Interface

Prism tools respond to natural language. Users can speak naturally and Claude maps to MCP tools:

| User says | Claude does |
|-----------|-------------|
| "go to line 42" | `goto_line(42)` |
| "open main.lua" | `open_file("main.lua")` |
| "show errors" | `get_diagnostics` |
| "fix this" | `code_actions(apply_first=true)` |
| "replace foo with bar" | `search_and_replace("foo", "bar")` |
| "be more careful" | `set_trust_mode("guardian")` |
| "teach me vim" | `set_config(narrated=true)` |

See CLAUDE.md for the complete NL reference.
