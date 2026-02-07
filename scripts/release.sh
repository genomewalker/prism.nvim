#!/bin/bash
# Release script for prism.nvim
# Usage: ./scripts/release.sh [patch|minor|major] [-y]
#
# Examples:
#   ./scripts/release.sh patch      # 0.1.0 -> 0.1.1
#   ./scripts/release.sh minor      # 0.1.0 -> 0.2.0
#   ./scripts/release.sh major      # 0.1.0 -> 1.0.0
#   ./scripts/release.sh patch -y   # Skip confirmation

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

# Parse arguments
BUMP_TYPE="${1:-patch}"
AUTO_CONFIRM=false
[[ "$2" == "-y" || "$1" == "-y" ]] && AUTO_CONFIRM=true
[[ "$1" == "-y" ]] && BUMP_TYPE="patch"

# Validate bump type
case "$BUMP_TYPE" in
    patch|minor|major) ;;
    *) error "Usage: $0 [patch|minor|major] [-y]" ;;
esac

# Get current version from pyproject.toml
PYPROJECT="pyproject.toml"
if [[ ! -f "$PYPROJECT" ]]; then
    error "pyproject.toml not found. Run from project root."
fi

CURRENT_VERSION=$(grep -E '^version\s*=' "$PYPROJECT" | sed 's/.*"\(.*\)".*/\1/')
if [[ -z "$CURRENT_VERSION" ]]; then
    error "Could not find version in pyproject.toml"
fi

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Calculate new version
case "$BUMP_TYPE" in
    major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
    minor) NEW_VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
    patch) NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
esac

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║          prism.nvim Release           ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""
info "Current version: ${YELLOW}${CURRENT_VERSION}${NC}"
info "New version:     ${GREEN}${NEW_VERSION}${NC}"
info "Bump type:       ${BLUE}${BUMP_TYPE}${NC}"
echo ""

# Check for uncommitted changes
if [[ -n $(git status --porcelain) ]]; then
    warn "You have uncommitted changes:"
    git status --short
    echo ""
    if ! $AUTO_CONFIRM; then
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo ""
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
fi

# Confirm release
if ! $AUTO_CONFIRM; then
    read -p "Create release v${NEW_VERSION}? (y/N) " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Update version in pyproject.toml
info "Updating pyproject.toml..."
sed -i.bak "s/^version = \"${CURRENT_VERSION}\"/version = \"${NEW_VERSION}\"/" "$PYPROJECT"
rm -f "${PYPROJECT}.bak"

# Update version in lua if exists
LUA_CORE="lua/prism/core.lua"
if [[ -f "$LUA_CORE" ]]; then
    if grep -q "M.version" "$LUA_CORE"; then
        info "Updating lua/prism/core.lua..."
        sed -i.bak "s/M.version = \".*\"/M.version = \"${NEW_VERSION}\"/" "$LUA_CORE"
        rm -f "${LUA_CORE}.bak"
    fi
fi

# Update version in plugin.json if exists
PLUGIN_JSON=".claude-plugin/plugin.json"
if [[ -f "$PLUGIN_JSON" ]]; then
    info "Updating .claude-plugin/plugin.json..."
    sed -i.bak "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" "$PLUGIN_JSON"
    rm -f "${PLUGIN_JSON}.bak"
fi

# Commit version bump
info "Committing version bump..."
git add "$PYPROJECT" "$LUA_CORE" "$PLUGIN_JSON" 2>/dev/null || git add "$PYPROJECT"
git commit -m "chore: bump version to ${NEW_VERSION}"

# Create tag
info "Creating tag v${NEW_VERSION}..."
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"

# Push
info "Pushing to remote..."
git push origin main
git push origin "v${NEW_VERSION}"

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║         Release Complete!             ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""
info "Version: ${GREEN}v${NEW_VERSION}${NC}"
info "Tag pushed - GitHub Actions will create the release"
echo ""
echo "  View release: https://github.com/genomewalker/prism.nvim/releases"
echo ""
