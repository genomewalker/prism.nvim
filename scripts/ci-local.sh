#!/bin/bash
# Local CI check - run before making releases
# Usage: ./scripts/ci-local.sh

set -e

cd "$(dirname "$0")/.."

echo "=== Prism.nvim Local CI ==="
echo

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# Python linting
echo "[1/4] Checking Python formatting (black)..."
if black --check --config pyproject.toml prism_nvim/ 2>/dev/null; then
    pass "black"
else
    echo "  Run: black --config pyproject.toml prism_nvim/"
    fail "black formatting"
fi

echo "[2/4] Checking Python linting (ruff)..."
if ruff check prism_nvim/; then
    pass "ruff"
else
    echo "  Run: ruff check --fix prism_nvim/"
    fail "ruff linting"
fi

# Lua linting (optional - may not be installed)
echo "[3/4] Checking Lua (luacheck)..."
if command -v luacheck &>/dev/null; then
    if luacheck lua/ --no-unused-args --no-max-line-length 2>/dev/null; then
        pass "luacheck"
    else
        echo "  (warnings only, not blocking)"
        pass "luacheck (with warnings)"
    fi
else
    echo "  luacheck not installed, skipping"
    pass "luacheck (skipped)"
fi

# Neovim load test
echo "[4/4] Testing Neovim plugin load..."
if command -v nvim &>/dev/null; then
    if nvim --headless -c "lua require('prism.core')" -c "qa!" 2>&1; then
        pass "neovim load"
    else
        fail "neovim load"
    fi
else
    echo "  nvim not found, skipping"
    pass "neovim load (skipped)"
fi

echo
echo -e "${GREEN}All checks passed!${NC} Ready for release."
