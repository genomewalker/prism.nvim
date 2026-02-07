#!/bin/bash
# Prism.nvim One-Liner Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/USER/prism.nvim/main/install.sh | bash
#    or: ./install.sh (from cloned repo)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[>]${NC} $1"; }

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║         Prism.nvim Installer          ║"
echo "  ║   Claude Code + Neovim Integration    ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

# Determine install directory
if [ -f "$(dirname "$0")/lua/prism/core.lua" ]; then
    PRISM_DIR="$(cd "$(dirname "$0")" && pwd)"
    info "Using local directory: $PRISM_DIR"
else
    PRISM_DIR="$HOME/.local/share/prism.nvim"
    if [ -d "$PRISM_DIR" ]; then
        info "Updating existing installation..."
        cd "$PRISM_DIR" && git pull
    else
        info "Cloning prism.nvim..."
        git clone https://github.com/genomewalker/prism.nvim.git "$PRISM_DIR"
    fi
fi

# Check requirements
command -v nvim >/dev/null 2>&1 || error "Neovim not found. Install from https://neovim.io"
command -v claude >/dev/null 2>&1 || warn "Claude CLI not found. Install from https://docs.anthropic.com/en/docs/claude-code"
command -v python3 >/dev/null 2>&1 || error "Python 3 not found"

# Install Python dependencies
info "Installing Python dependencies..."
python3 -m pip install --quiet --user msgpack 2>/dev/null || pip install --quiet msgpack

# ============================================================================
# Step 1: Neovim Plugin
# ============================================================================
step "Setting up Neovim plugin..."

PACK_DIR="$HOME/.local/share/nvim/site/pack/prism/start"
mkdir -p "$PACK_DIR"

if [ -L "$PACK_DIR/prism.nvim" ]; then
    rm "$PACK_DIR/prism.nvim"
fi
ln -sf "$PRISM_DIR" "$PACK_DIR/prism.nvim"
info "Neovim plugin linked: $PACK_DIR/prism.nvim"

# ============================================================================
# Step 2: Claude Code MCP Configuration
# ============================================================================
step "Configuring Claude Code MCP server..."

CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"

# Create or update settings.json with MCP server
if [ -f "$CLAUDE_SETTINGS" ]; then
    if grep -q "prism-nvim" "$CLAUDE_SETTINGS" 2>/dev/null; then
        info "MCP server already configured"
    else
        cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"
        python3 << EOF
import json

settings_file = "$CLAUDE_SETTINGS"
prism_dir = "$PRISM_DIR"

try:
    with open(settings_file, 'r') as f:
        settings = json.load(f)
except:
    settings = {}

if 'mcpServers' not in settings:
    settings['mcpServers'] = {}

settings['mcpServers']['prism-nvim'] = {
    "type": "stdio",
    "command": "python3",
    "args": ["-m", "prism_nvim.mcp_server"],
    "cwd": prism_dir
}

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
EOF
        info "MCP server added (backup: settings.json.bak)"
    fi
else
    cat > "$CLAUDE_SETTINGS" << EOF
{
  "mcpServers": {
    "prism-nvim": {
      "type": "stdio",
      "command": "python3",
      "args": ["-m", "prism_nvim.mcp_server"],
      "cwd": "$PRISM_DIR"
    }
  }
}
EOF
    info "Created Claude settings with MCP server"
fi

# ============================================================================
# Step 3: Install /prism skill
# ============================================================================
step "Installing /prism skill..."

SKILLS_DIR="$CLAUDE_DIR/skills"
mkdir -p "$SKILLS_DIR"

if [ -L "$SKILLS_DIR/prism" ]; then
    rm "$SKILLS_DIR/prism"
fi
ln -sf "$PRISM_DIR/skills/prism" "$SKILLS_DIR/prism"
info "Skill installed: /prism is now available in Claude Code"

# ============================================================================
# Step 4: Global CLAUDE.md (teaches Claude to use MCP tools)
# ============================================================================
step "Setting up Claude instructions (CLAUDE.md)..."

CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"

# Append prism instructions if not already present
if [ -f "$CLAUDE_MD" ]; then
    if grep -q "Prism.nvim MCP" "$CLAUDE_MD" 2>/dev/null; then
        info "Prism instructions already in CLAUDE.md"
    else
        cp "$CLAUDE_MD" "$CLAUDE_MD.bak"
        cat >> "$CLAUDE_MD" << 'EOF'

# Prism.nvim MCP Integration

When connected to Neovim via prism.nvim MCP server, **prefer MCP tools over standard Claude Code tools** to save tokens.

## Tool Priority

1. **MCP tools** (when Neovim connected) - minimal tokens
2. **Standard tools** (fallback) - when MCP unavailable

## Token-Saving Mappings

| Task | Use MCP | Instead of |
|------|---------|------------|
| Read file | `mcp__prism-nvim__get_buffer_content` | `Read` |
| Edit file | `mcp__prism-nvim__run_command("%s/old/new/g")` | `Edit` |
| Open file | `mcp__prism-nvim__open_file` | `Read` |
| Save file | `mcp__prism-nvim__save_file` | (automatic) |
| Search | `mcp__prism-nvim__search_in_file` | `Grep` |

## Vim Commands via run_command

```vim
%s/old/new/g          " Replace all in file
10,20s/old/new/g      " Replace in line range
1wincmd w | %s/x/y/g  " Switch to editor, then replace
```

## Check MCP Connection

Before using MCP, verify connection:
```
mcp__prism-nvim__get_current_file
```

If this fails, fall back to standard tools.

## Why Use MCP?

- **10-50x token savings**: vim commands are ~20 tokens vs ~1000+ for file contents
- **Direct editor control**: Changes appear instantly in Neovim
- **Terminal protection**: run_command auto-protects terminal window
EOF
        info "Prism instructions added to CLAUDE.md (backup: CLAUDE.md.bak)"
    fi
else
    cat > "$CLAUDE_MD" << 'EOF'
# Global Claude Instructions

## Prism.nvim MCP Integration

When connected to Neovim via prism.nvim MCP server, **prefer MCP tools over standard Claude Code tools** to save tokens.

### Tool Priority

1. **MCP tools** (when Neovim connected) - minimal tokens
2. **Standard tools** (fallback) - when MCP unavailable

### Token-Saving Mappings

| Task | Use MCP | Instead of |
|------|---------|------------|
| Read file | `mcp__prism-nvim__get_buffer_content` | `Read` |
| Edit file | `mcp__prism-nvim__run_command("%s/old/new/g")` | `Edit` |
| Open file | `mcp__prism-nvim__open_file` | `Read` |
| Save file | `mcp__prism-nvim__save_file` | (automatic) |
| Search | `mcp__prism-nvim__search_in_file` | `Grep` |

### Vim Commands via run_command

```vim
%s/old/new/g          " Replace all in file
10,20s/old/new/g      " Replace in line range
1wincmd w | %s/x/y/g  " Switch to editor, then replace
```

### Check MCP Connection

Before using MCP, verify connection:
```
mcp__prism-nvim__get_current_file
```

If this fails, fall back to standard tools.

### Why Use MCP?

- **10-50x token savings**: vim commands are ~20 tokens vs ~1000+ for file contents
- **Direct editor control**: Changes appear instantly in Neovim
- **Terminal protection**: run_command auto-protects terminal window
EOF
    info "Created CLAUDE.md with Prism instructions"
fi

# ============================================================================
# Step 5: Neovim Config
# ============================================================================
step "Checking Neovim configuration..."

NVIM_CONFIG_DIR="$HOME/.config/nvim"
NVIM_INIT="$NVIM_CONFIG_DIR/init.lua"

# Create prism config file
PRISM_CONFIG="$NVIM_CONFIG_DIR/lua/plugins/prism.lua"
mkdir -p "$(dirname "$PRISM_CONFIG")"

if [ -f "$PRISM_CONFIG" ]; then
    info "Prism config already exists: $PRISM_CONFIG"
else
    cat > "$PRISM_CONFIG" << 'EOF'
-- Prism.nvim Configuration
-- Claude Code integration with MCP control

return {
  dir = vim.fn.expand("~/.local/share/nvim/site/pack/prism/start/prism.nvim"),
  lazy = false,
  config = function()
    require("prism.core").setup({
      -- Terminal
      toggle_key = "<C-;>",      -- Toggle Claude terminal
      terminal_width = 0.4,      -- 40% of screen width

      -- Behavior
      auto_reload = true,        -- Reload buffers when Claude edits files
      notify = true,             -- Show notifications

      -- MCP Server (lets Claude control Neovim)
      mcp = true,                -- Enable MCP server

      -- Passthrough Mode (real terminal feel)
      passthrough = true,        -- Only Ctrl+\ Ctrl+\ escapes to normal mode

      -- Claude CLI args (optional)
      -- claude_args = "--model opus",  -- Or use CLAUDE_ARGS env var
    })
  end,
}
EOF
    info "Created Neovim config: $PRISM_CONFIG"
fi

# Check if using lazy.nvim
if [ -d "$NVIM_CONFIG_DIR/lua/plugins" ] && grep -rq "lazy" "$NVIM_CONFIG_DIR" 2>/dev/null; then
    info "Detected lazy.nvim - config file ready"
else
    warn "Add to your init.lua: require('prism.core').setup()"
fi

# ============================================================================
# Step 6: Shell Helpers (optional)
# ============================================================================
step "Setting up shell helpers..."

SHELL_RC=""
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_RC="$HOME/.bash_profile"
elif [ -f "$HOME/.profile" ]; then
    SHELL_RC="$HOME/.profile"
fi

if [ -n "$SHELL_RC" ]; then
    if grep -q "CLAUDE_ARGS" "$SHELL_RC" 2>/dev/null; then
        info "Shell helpers already configured"
    else
        cat >> "$SHELL_RC" << 'EOF'

# Prism.nvim - nvim + Claude Code
# Usage: nvc [claude-flags] [--] [files]
# All flags before files (or --) go to Claude, rest to nvim
# Examples:
#   nvc                       # Just nvim with Claude
#   nvc -c                    # Resume last conversation
#   nvc --model opus          # Use Opus model
#   nvc -c --model opus       # Continue with Opus
#   nvc --allowedTools Edit   # Only allow Edit tool
#   nvc -- -O file1 file2     # Pass -O to nvim (use -- separator)
#   nvc myfile.lua            # Open file
nvc() {
  local claude_args=()
  local nvim_args=()
  local parsing_claude=true

  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      parsing_claude=false
      shift
      continue
    fi

    if $parsing_claude; then
      case "$1" in
        -c) claude_args+=("--continue"); shift ;;
        --*=*) claude_args+=("$1"); shift ;;  # --flag=value
        --*|-*)
          claude_args+=("$1")
          # Check if next arg is the value (not a flag or file)
          if [[ -n "$2" && ! "$2" =~ ^- && ! -e "$2" ]]; then
            claude_args+=("$2")
            shift
          fi
          shift
          ;;
        *) parsing_claude=false; nvim_args+=("$1"); shift ;;
      esac
    else
      nvim_args+=("$1"); shift
    fi
  done

  CLAUDE_ARGS="${claude_args[*]}" nvim "${nvim_args[@]}"
}
EOF
        info "Added nvc function to $SHELL_RC"
        echo "     nvc           = nvim with Claude"
        echo "     nvc -c        = resume last conversation"
        echo "     nvc --model opus = use Opus model"
    fi
fi

# ============================================================================
# Done!
# ============================================================================
echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║        Installation Complete!         ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""
echo "  What was installed:"
echo "    ✓ Neovim plugin (native packages)"
echo "    ✓ Claude Code MCP server config"
echo "    ✓ CLAUDE.md with MCP instructions"
echo "    ✓ Neovim config file"
echo "    ✓ Shell function (nvc)"
echo ""
echo "  Next steps:"
echo ""
echo "    1. Restart your shell:  source $SHELL_RC"
echo "    2. Open Neovim:         nvim"
echo "    3. Toggle Claude:       Ctrl+;"
echo ""
echo "  Keybindings:"
echo "    Ctrl+;           Toggle Claude terminal"
echo "    Ctrl+\\ Ctrl+\\    Exit terminal mode"
echo "    <leader>cs       Send selection to Claude"
echo "    ]g               Next file Claude changed"
echo ""
echo "  Token-saving: Claude will now use MCP tools"
echo "  automatically for 10-50x fewer tokens!"
echo ""
