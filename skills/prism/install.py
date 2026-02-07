#!/usr/bin/env python3
"""
Prism.nvim Installer - Claude-centric installation
Run with: python3 install.py
"""

import json
import os
import subprocess
import sys
from pathlib import Path

# Colors
GREEN = "\033[92m"
YELLOW = "\033[93m"
BLUE = "\033[94m"
RED = "\033[91m"
NC = "\033[0m"

def info(msg): print(f"{GREEN}[+]{NC} {msg}")
def warn(msg): print(f"{YELLOW}[!]{NC} {msg}")
def step(msg): print(f"{BLUE}[>]{NC} {msg}")
def error(msg): print(f"{RED}[x]{NC} {msg}"); sys.exit(1)

def run(cmd, check=True):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        error(f"Command failed: {cmd}\n{result.stderr}")
    return result

def main():
    print()
    print("  ╔═══════════════════════════════════════╗")
    print("  ║         Prism.nvim Installer          ║")
    print("  ║   Claude Code + Neovim Integration    ║")
    print("  ╚═══════════════════════════════════════╝")
    print()

    home = Path.home()
    prism_dir = home / ".local/share/prism.nvim"
    claude_dir = home / ".claude"
    nvim_config = home / ".config/nvim"

    # Step 1: Clone/update repository
    step("Installing prism.nvim...")
    if prism_dir.exists():
        info("Updating existing installation...")
        run(f"cd {prism_dir} && git pull", check=False)
    else:
        info("Cloning prism.nvim...")
        run(f"git clone https://github.com/genomewalker/prism.nvim.git {prism_dir}")

    # Step 2: Python dependencies
    step("Installing Python dependencies...")
    run("python3 -m pip install --user --quiet msgpack", check=False)
    info("msgpack installed")

    # Step 3: Neovim plugin
    step("Setting up Neovim plugin...")
    pack_dir = home / ".local/share/nvim/site/pack/prism/start"
    pack_dir.mkdir(parents=True, exist_ok=True)
    link_path = pack_dir / "prism.nvim"
    if link_path.is_symlink():
        link_path.unlink()
    link_path.symlink_to(prism_dir)
    info(f"Linked: {link_path}")

    # Step 4: MCP server config
    step("Configuring Claude Code MCP...")
    claude_dir.mkdir(exist_ok=True)
    settings_file = claude_dir / "settings.json"

    settings = {}
    if settings_file.exists():
        try:
            settings = json.loads(settings_file.read_text())
        except:
            pass

    if "mcpServers" not in settings:
        settings["mcpServers"] = {}

    settings["mcpServers"]["prism-nvim"] = {
        "type": "stdio",
        "command": "python3",
        "args": ["-m", "prism_nvim.mcp_server"],
        "cwd": str(prism_dir)
    }

    settings_file.write_text(json.dumps(settings, indent=2))
    info("MCP server registered")

    # Step 5: CLAUDE.md instructions
    step("Adding Claude instructions...")
    claude_md = claude_dir / "CLAUDE.md"

    prism_instructions = '''
# Prism.nvim MCP Integration

When connected to Neovim via prism.nvim, **prefer MCP tools over standard tools**:

| Task | MCP Tool | Instead of |
|------|----------|------------|
| Read file | `mcp__prism-nvim__get_buffer_content` | `Read` |
| Edit file | `mcp__prism-nvim__run_command("%s/old/new/g")` | `Edit` |
| Open file | `mcp__prism-nvim__open_file` | `Read` |
| Save | `mcp__prism-nvim__save_file` | automatic |

**Why**: 10-50x token savings. Vim commands are ~20 tokens vs ~1000+ for file contents.

**Check connection**: `mcp__prism-nvim__get_current_file`
'''

    if claude_md.exists():
        content = claude_md.read_text()
        if "Prism.nvim MCP" not in content:
            claude_md.write_text(content + prism_instructions)
            info("Added Prism instructions to CLAUDE.md")
        else:
            info("Prism instructions already in CLAUDE.md")
    else:
        claude_md.write_text("# Claude Instructions\n" + prism_instructions)
        info("Created CLAUDE.md with Prism instructions")

    # Step 6: Neovim config
    step("Creating Neovim config...")
    plugins_dir = nvim_config / "lua/plugins"
    plugins_dir.mkdir(parents=True, exist_ok=True)
    prism_config = plugins_dir / "prism.lua"

    if not prism_config.exists():
        prism_config.write_text('''-- Prism.nvim - Claude Code integration
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
''')
        info(f"Created: {prism_config}")
    else:
        info("Neovim config already exists")

    # Step 7: Shell aliases
    step("Adding shell aliases...")
    shell_rc = home / ".zshrc" if (home / ".zshrc").exists() else home / ".bashrc"

    if shell_rc.exists():
        content = shell_rc.read_text()
        if "CLAUDE_ARGS" not in content:
            with open(shell_rc, "a") as f:
                f.write('''
# Prism.nvim helpers
alias nvc='CLAUDE_ARGS="--continue" nvim'
alias nvco='CLAUDE_ARGS="--model opus" nvim'
alias nvcs='CLAUDE_ARGS="--model sonnet" nvim'
''')
            info(f"Added aliases to {shell_rc}")
        else:
            info("Shell aliases already configured")

    # Done!
    print()
    print("  ╔═══════════════════════════════════════╗")
    print("  ║        Installation Complete!         ║")
    print("  ╚═══════════════════════════════════════╝")
    print()
    print("  Next steps:")
    print()
    print("    1. Restart Claude Code (to load MCP)")
    print("    2. Open Neovim")
    print("    3. Press Ctrl+; to toggle Claude")
    print()
    print("  Keybindings:")
    print("    Ctrl+;           Toggle Claude terminal")
    print("    Ctrl+\\ Ctrl+\\    Exit terminal mode")
    print("    <leader>cs       Send to Claude")
    print()
    print("  Token savings: Claude now uses MCP for 10-50x fewer tokens!")
    print()

if __name__ == "__main__":
    main()
