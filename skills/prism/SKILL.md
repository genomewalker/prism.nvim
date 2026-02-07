---
name: prism
description: Install and configure prism.nvim - Neovim integration with token-saving MCP tools
argument-hint: "[install|update|status|help]"
execution: direct
---

# Prism.nvim - Claude Code + Neovim Integration

Claude controls your editor directly. Talk to it. Watch it edit. 55+ MCP tools with 10-50x token savings.

## Handle Arguments

Based on `$ARGUMENTS`:

- **install** (or no args): Run full installation (idempotent)
- **update**: Update prism to latest version
- **status**: Check installation status and MCP connection
- **help**: Show usage information and available commands

---

## Command: help

Display this information:

```
/prism - Neovim integration with Claude Code

Commands:
  /prism install  - Install or reinstall prism.nvim (idempotent)
  /prism update   - Update to latest version
  /prism status   - Check installation and MCP connection
  /prism help     - Show this help

After install:
  1. Restart Claude Code to load MCP server
  2. Open Neovim, press Ctrl+; to toggle Claude terminal
  3. Talk naturally: "go to line 42", "fix this error", "commit with message X"

Shell commands (after install):
  nvc              - Open nvim with Claude
  nvc -c           - Continue last conversation
  nvc --model opus - Use Opus model
  nvco             - Shortcut for nvc --model opus
```

---

## Command: update

Quick update without full reinstall:

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
if [ ! -d "$PRISM_DIR" ]; then
  echo "Prism not installed. Run /prism install first."
  exit 1
fi

cd "$PRISM_DIR"
OLD_VERSION=$(grep '^version' pyproject.toml 2>/dev/null | cut -d'"' -f2)
echo "Current version: $OLD_VERSION"

git fetch origin main --quiet
BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")

if [ "$BEHIND" -eq 0 ]; then
  echo "Already up to date"
else
  echo "Updating ($BEHIND commits behind)..."
  git pull
  NEW_VERSION=$(grep '^version' pyproject.toml | cut -d'"' -f2)
  echo "Updated to version: $NEW_VERSION"

  if [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
    echo ""
    echo "Version changed: $OLD_VERSION -> $NEW_VERSION"
    echo "Restart Claude Code to apply changes."
  fi
fi
```

**After git pull, check if shell functions need updating:**

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
REF_BASH="$PRISM_DIR/scripts/shell/nvc.bash"

for rc in ~/.zshrc ~/.bashrc; do
  if [ -f "$rc" ] && grep -q "nvc()" "$rc"; then
    installed=$(sed -n '/^# Prism.nvim helpers/,/^alias nvco=/p' "$rc")
    ref_content=$(cat "$REF_BASH")
    if [ "$installed" != "$ref_content" ]; then
      echo "shell_$(basename $rc):outdated"
    fi
  fi
done
```

If any shell functions are outdated, use AskUserQuestion:

```
question: "Your nvc shell function is outdated. Update to latest version?"
header: "Update nvc"
options:
  - label: "Yes, update (Recommended)"
    description: "Replace old nvc function with latest version"
  - label: "No, keep current"
    description: "Keep your existing function"
```

If user says yes, update the function:
```bash
sed -i.bak '/^# Prism.nvim helpers/,/^alias nvco=/d' ~/.bashrc  # or ~/.zshrc
cat "$PRISM_DIR/scripts/shell/nvc.bash" >> ~/.bashrc  # or ~/.zshrc
echo "Shell function updated. Run: source ~/.bashrc"
```

After running, tell the user:
- If version changed: **Restart Claude Code** to load updated MCP server
- If shell updated: **Source your rc file** or restart terminal
- Check the changelog for new features

---

## Command: status

Run these checks and report results in a table:

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
if [ -d "$PRISM_DIR" ]; then
  cd "$PRISM_DIR"
  LOCAL_VERSION=$(grep '^version' pyproject.toml 2>/dev/null | cut -d'"' -f2)
  git fetch origin main --quiet 2>/dev/null
  BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "?")
  echo "version:$LOCAL_VERSION"
  echo "behind:$BEHIND"
else
  echo "version:not installed"
fi
```

```bash
python3 -c "import msgpack" 2>/dev/null && echo "msgpack:ok" || echo "msgpack:missing"
[ -L ~/.local/share/nvim/site/pack/prism/start/prism.nvim ] && echo "plugin:linked" || echo "plugin:missing"
grep -q '"prism-nvim"' ~/.claude/settings.json 2>/dev/null && echo "mcp:configured" || echo "mcp:missing"
[ -L ~/.claude/rules/prism-nvim.md ] && echo "rules:linked" || echo "rules:missing"
[ -f ~/.config/nvim/lua/plugins/prism.lua ] && echo "nvim_config:exists" || echo "nvim_config:missing"
```

```bash
# Check shell aliases with md5sum comparison against reference
PRISM_DIR="$HOME/.local/share/prism.nvim"
REF_HASH=$(md5sum "$PRISM_DIR/scripts/shell/nvc.bash" 2>/dev/null | cut -d' ' -f1)

check_shell_func() {
  local rc="$1"
  local name="$2"
  if [ ! -f "$rc" ]; then return; fi
  if ! grep -q "nvc()" "$rc" 2>/dev/null; then return; fi

  # Extract nvc function block from rc file
  local installed=$(sed -n '/^# Prism.nvim helpers/,/^alias nvco=/p' "$rc" 2>/dev/null)
  if [ -z "$installed" ]; then
    # Try alternate extraction - just the function
    installed=$(sed -n '/^nvc()/,/^}/p' "$rc" 2>/dev/null)
  fi

  if [ -n "$installed" ]; then
    local inst_hash=$(echo "$installed" | md5sum | cut -d' ' -f1)
    if [ "$inst_hash" = "$REF_HASH" ]; then
      echo "shell_$name:current"
    else
      echo "shell_$name:outdated"
    fi
  else
    echo "shell_$name:configured"
  fi
}

check_shell_func ~/.zshrc zsh
check_shell_func ~/.bashrc bash
grep -q "nvc()" ~/.zshrc ~/.bashrc 2>/dev/null || echo "shell:missing"
```

Also try MCP connection: `mcp__prism-nvim__get_current_file`
- If it works: MCP connected
- If it fails: MCP not connected (Neovim may not be running)

Present results as:

| Component | Status |
|-----------|--------|
| Version | X.Y.Z (N commits behind) |
| Python msgpack | OK / Missing |
| Neovim plugin | Linked / Missing |
| MCP server | Configured / Missing |
| Rules | Linked / Missing |
| Nvim config | Exists / Missing |
| Shell alias | Current / Outdated / Missing |
| MCP connection | Connected / Not connected |

If any component is missing, suggest running `/prism install`.
If shell alias shows "Outdated", suggest running `/prism install` to update the nvc function.

---

## Command: install

Full installation (all steps are idempotent - safe to run multiple times).

### Step 1: Clone or Update Repository

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
if [ -d "$PRISM_DIR" ]; then
  cd "$PRISM_DIR"
  LOCAL_VERSION=$(grep '^version' pyproject.toml 2>/dev/null | cut -d'"' -f2)
  echo "Current version: $LOCAL_VERSION"

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
  echo "Neovim plugin linked"
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
        mcp = { auto_start = false },
        terminal = {
          provider = "native",
          position = "vertical",
          width = 0.4,
          auto_start = false,
          passthrough = true,
        },
        claude = { model = nil, continue_session = false },
        trust = { mode = "companion" },
      })
    end,
    keys = {
      { "<leader>cc", "<cmd>Prism<cr>", desc = "Prism: Open Layout" },
      { "<leader>ct", "<cmd>PrismToggle<cr>", desc = "Prism: Toggle Terminal" },
      { "<leader>cs", "<cmd>PrismSend<cr>", mode = { "n", "v" }, desc = "Prism: Send to Claude" },
      { "<leader>ca", "<cmd>PrismAction<cr>", mode = { "n", "v" }, desc = "Prism: Code Actions" },
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
echo "Rules linked"
```

### Step 7: Add or Update Shell Aliases

**First, check existing shell functions and compare with reference:**

```bash
PRISM_DIR="$HOME/.local/share/prism.nvim"
REF_BASH="$PRISM_DIR/scripts/shell/nvc.bash"
REF_FISH="$PRISM_DIR/scripts/shell/nvc.fish"

# Check each shell rc file
for rc in ~/.zshrc ~/.bashrc; do
  if [ -f "$rc" ] && grep -q "nvc()" "$rc"; then
    # Extract installed function
    installed=$(sed -n '/^# Prism.nvim helpers/,/^alias nvco=/p' "$rc")
    ref_content=$(cat "$REF_BASH")

    if [ "$installed" != "$ref_content" ]; then
      echo "shell_$(basename $rc):outdated"
    else
      echo "shell_$(basename $rc):current"
    fi
  else
    echo "shell_$(basename $rc):missing"
  fi
done
```

**If missing:** Use AskUserQuestion to ask which shell:

```
question: "Which shell do you use?"
header: "Shell"
options:
  - label: "Zsh"
    description: "Add aliases to ~/.zshrc"
  - label: "Bash"
    description: "Add aliases to ~/.bashrc"
  - label: "Fish"
    description: "Add functions to ~/.config/fish/functions/"
  - label: "Skip"
    description: "Don't add shell aliases"
```

**If outdated:** Use AskUserQuestion to offer update:

```
question: "Your nvc shell function is outdated. Update to latest version?"
header: "Update"
options:
  - label: "Yes, update it (Recommended)"
    description: "Replace old nvc function with latest version"
  - label: "No, keep current"
    description: "Keep your existing function (may miss bug fixes)"
```

**To update outdated function:** Remove old block and append new:

```bash
# Remove old prism block from rc file
sed -i.bak '/^# Prism.nvim helpers/,/^alias nvco=/d' ~/.bashrc  # or ~/.zshrc

# Append new version
cat "$PRISM_DIR/scripts/shell/nvc.bash" >> ~/.bashrc  # or ~/.zshrc
```

**For new installs, append the reference file:**

```bash
# For Bash/Zsh - append the reference file
cat "$PRISM_DIR/scripts/shell/nvc.bash" >> ~/.bashrc  # or ~/.zshrc
```

**For Fish** (`~/.config/fish/functions/nvc.fish`):

```bash
# Copy reference file for Fish
mkdir -p ~/.config/fish/functions
cp "$PRISM_DIR/scripts/shell/nvc.fish" ~/.config/fish/functions/nvc.fish
```

---

## After Installation

Tell the user:

1. **Restart Claude Code** to load the MCP server
2. **Open Neovim** - prism loads automatically
3. **Press Ctrl+;** to toggle Claude terminal
4. **Use Ctrl+\ Ctrl+\** to exit terminal mode (passthrough)

## Token Savings

Explain that MCP tools save tokens because:
- Vim commands are ~20 tokens (e.g., `%s/old/new/g`)
- Standard Edit tool sends full file content (~500-2000 tokens)
- For a 500-line file, that's **25-100x savings per edit**

## Natural Language Interface

Prism's 55+ MCP tools respond to natural language:

| You say | Claude does |
|---------|-------------|
| "go to line 42" | `goto_line(42)` |
| "show me errors" | `get_diagnostics` |
| "fix this error" | `fix_diagnostic` |
| "replace foo with bar" | `search_and_replace("foo", "bar")` |
| "be more careful" | `set_trust_mode("guardian")` |
| "just do it" | `set_trust_mode("autopilot")` |
| "teach me vim" | `set_config(narrated=true)` |
| "commit with message X" | `git_commit("X")` |
| "who wrote this?" | `git_blame` |

See CLAUDE.md for the complete natural language reference.
