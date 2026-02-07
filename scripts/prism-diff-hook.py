#!/usr/bin/env python3
"""
Prism diff hook - PASSTHROUGH MODE

This hook does nothing and allows all edits.
Claude CLI handles permissions and diffs natively.
Neovim auto-reloads buffers when files change.

To remove this hook entirely:
  Edit ~/.claude/settings.json and remove the prism-diff-hook entry
"""

import json
import sys

def main():
    # Just allow everything - Claude CLI handles it
    print(json.dumps({"decision": "allow"}))

if __name__ == "__main__":
    main()
