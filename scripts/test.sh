#!/usr/bin/env bash
# prism.nvim test runner
# Usage: ./scripts/test.sh [options] [test_file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
VERBOSE=false
COVERAGE=false
WATCH=false
TEST_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -c|--coverage)
            COVERAGE=true
            shift
            ;;
        -w|--watch)
            WATCH=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options] [test_file]"
            echo ""
            echo "Options:"
            echo "  -v, --verbose    Verbose output"
            echo "  -c, --coverage   Generate coverage report"
            echo "  -w, --watch      Watch for changes and re-run tests"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                        Run all tests"
            echo "  $0 tests/diff_spec.lua    Run specific test file"
            echo "  $0 -v -c                  Run with verbose + coverage"
            exit 0
            ;;
        *)
            TEST_FILE="$1"
            shift
            ;;
    esac
done

# Check for required tools
check_dependencies() {
    local missing=()

    if ! command -v nvim &> /dev/null; then
        missing+=("nvim")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required tools: ${missing[*]}${NC}"
        exit 1
    fi

    # Check Neovim version
    local nvim_version
    nvim_version=$(nvim --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local major minor
    major=$(echo "$nvim_version" | cut -d. -f1)
    minor=$(echo "$nvim_version" | cut -d. -f2)

    if [[ $major -lt 1 && $minor -lt 9 ]]; then
        echo -e "${YELLOW}Warning: Neovim 0.9+ recommended (found $nvim_version)${NC}"
    fi
}

# Create minimal init.lua for testing
create_test_init() {
    local init_file="$PROJECT_ROOT/tests/minimal_init.lua"

    cat > "$init_file" << 'EOF'
-- Minimal init.lua for prism.nvim testing
vim.cmd([[set runtimepath+=.]])

-- Add plenary to runtimepath if available
local plenary_paths = {
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
    vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim",
    vim.fn.stdpath("data") .. "/plugged/plenary.nvim",
    vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
}

for _, path in ipairs(plenary_paths) do
    if vim.fn.isdirectory(path) == 1 then
        vim.opt.runtimepath:append(path)
        break
    end
end

-- Disable swap files for tests
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false

-- Faster test execution
vim.opt.updatetime = 100
vim.opt.timeoutlen = 500

-- Load prism
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Set up globals for tests
_G.TEST_MODE = true
EOF

    echo "$init_file"
}

# Run tests with plenary
run_tests() {
    local init_file
    init_file=$(create_test_init)

    local test_cmd

    if [[ -n "$TEST_FILE" ]]; then
        test_cmd="PlenaryBustedFile $TEST_FILE"
    else
        test_cmd="PlenaryBustedDirectory tests/ {minimal_init = '$init_file'}"
    fi

    echo -e "${BLUE}Running tests...${NC}"
    echo ""

    local nvim_args=(
        --headless
        -u "$init_file"
        -c "$test_cmd"
    )

    if $VERBOSE; then
        nvim "${nvim_args[@]}"
    else
        nvim "${nvim_args[@]}" 2>&1 | grep -E '(Success|Failed|Error|PASS|FAIL|^[0-9]+ success)' || true
    fi

    local exit_code=${PIPESTATUS[0]}

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
    else
        echo -e "${RED}Some tests failed.${NC}"
    fi

    return "$exit_code"
}

# Run tests with coverage (using luacov if available)
run_tests_with_coverage() {
    echo -e "${BLUE}Running tests with coverage...${NC}"

    # Check if luacov is available
    if ! nvim --headless -c "lua print(pcall(require, 'luacov'))" -c "q" 2>&1 | grep -q "true"; then
        echo -e "${YELLOW}Warning: luacov not found, running tests without coverage${NC}"
        run_tests
        return
    fi

    local init_file
    init_file=$(create_test_init)

    # Add luacov to init
    cat >> "$init_file" << 'EOF'
-- Enable coverage
pcall(require, 'luacov')
EOF

    run_tests

    # Generate coverage report if luacov stats exist
    if [[ -f "luacov.stats.out" ]]; then
        echo ""
        echo -e "${BLUE}Generating coverage report...${NC}"
        nvim --headless -c "lua require('luacov.reporter'):run()" -c "q" 2>/dev/null || true

        if [[ -f "luacov.report.out" ]]; then
            echo -e "${GREEN}Coverage report: luacov.report.out${NC}"
            tail -20 luacov.report.out
        fi
    fi
}

# Watch mode using entr or fswatch
run_watch() {
    echo -e "${BLUE}Watching for changes...${NC}"
    echo "Press Ctrl+C to stop"
    echo ""

    if command -v entr &> /dev/null; then
        find "$PROJECT_ROOT/lua" "$PROJECT_ROOT/tests" -name "*.lua" | entr -c "$0" "$TEST_FILE"
    elif command -v fswatch &> /dev/null; then
        fswatch -o "$PROJECT_ROOT/lua" "$PROJECT_ROOT/tests" | while read -r; do
            clear
            "$0" "$TEST_FILE"
        done
    else
        echo -e "${RED}Error: Watch mode requires 'entr' or 'fswatch'${NC}"
        echo "Install with: brew install entr  OR  brew install fswatch"
        exit 1
    fi
}

# Create sample test files if tests directory is empty
ensure_test_files() {
    local tests_dir="$PROJECT_ROOT/tests"

    if [[ ! -d "$tests_dir" ]]; then
        mkdir -p "$tests_dir"
    fi

    # Create diff test if it doesn't exist
    if [[ ! -f "$tests_dir/diff_spec.lua" ]]; then
        cat > "$tests_dir/diff_spec.lua" << 'EOF'
-- Tests for prism.diff module
local compute = require("prism.diff.compute")

describe("diff.compute", function()
    before_each(function()
        compute.reset_counter()
    end)

    describe("compute()", function()
        it("should return empty array for identical content", function()
            local old = { "line 1", "line 2" }
            local new = { "line 1", "line 2" }
            local hunks = compute.compute(old, new)
            assert.are.equal(0, #hunks)
        end)

        it("should detect additions", function()
            local old = { "line 1" }
            local new = { "line 1", "line 2" }
            local hunks = compute.compute(old, new)
            assert.are.equal(1, #hunks)
            assert.are.equal("add", hunks[1].type)
        end)

        it("should detect deletions", function()
            local old = { "line 1", "line 2" }
            local new = { "line 1" }
            local hunks = compute.compute(old, new)
            assert.are.equal(1, #hunks)
            assert.are.equal("delete", hunks[1].type)
        end)

        it("should detect changes", function()
            local old = { "line 1", "old line", "line 3" }
            local new = { "line 1", "new line", "line 3" }
            local hunks = compute.compute(old, new)
            assert.are.equal(1, #hunks)
            assert.are.equal("change", hunks[1].type)
        end)

        it("should track hunk metadata", function()
            local old = { "a" }
            local new = { "b" }
            local hunks = compute.compute(old, new, "test.lua")
            assert.are.equal("test.lua", hunks[1].file)
            assert.are.equal("pending", hunks[1].status)
            assert.is_number(hunks[1].id)
        end)
    end)

    describe("apply_hunk()", function()
        it("should apply addition hunk correctly", function()
            local lines = { "line 1", "line 3" }
            local hunk = {
                type = "add",
                start_line = 2,
                new_lines = { "line 2" },
            }
            local result = compute.apply_hunk(lines, hunk)
            assert.are.equal(3, #result)
            assert.are.equal("line 2", result[2])
        end)

        it("should apply deletion hunk correctly", function()
            local lines = { "line 1", "line 2", "line 3" }
            local hunk = {
                type = "delete",
                old_start = 2,
                old_lines = { "line 2" },
            }
            local result = compute.apply_hunk(lines, hunk)
            assert.are.equal(2, #result)
            assert.are.equal("line 1", result[1])
            assert.are.equal("line 3", result[2])
        end)
    end)

    describe("get_hunk_offset()", function()
        it("should return positive offset for additions", function()
            local hunk = { old_lines = {}, new_lines = { "a", "b" } }
            assert.are.equal(2, compute.get_hunk_offset(hunk))
        end)

        it("should return negative offset for deletions", function()
            local hunk = { old_lines = { "a", "b" }, new_lines = {} }
            assert.are.equal(-2, compute.get_hunk_offset(hunk))
        end)

        it("should return zero for same-size changes", function()
            local hunk = { old_lines = { "a" }, new_lines = { "b" } }
            assert.are.equal(0, compute.get_hunk_offset(hunk))
        end)
    end)
end)
EOF
        echo -e "${YELLOW}Created sample test: tests/diff_spec.lua${NC}"
    fi

    # Create config test if it doesn't exist
    if [[ ! -f "$tests_dir/config_spec.lua" ]]; then
        cat > "$tests_dir/config_spec.lua" << 'EOF'
-- Tests for prism.config module
local config = require("prism.config")

describe("config", function()
    before_each(function()
        config.reset()
    end)

    describe("defaults()", function()
        it("should return default configuration", function()
            local defaults = config.defaults()
            assert.is_table(defaults)
            assert.is_table(defaults.terminal)
            assert.is_table(defaults.mcp)
            assert.is_table(defaults.ui)
        end)
    end)

    describe("setup()", function()
        it("should merge user options with defaults", function()
            config.setup({
                terminal = { width = 0.5 },
            })
            assert.are.equal(0.5, config.get("terminal.width"))
        end)

        it("should preserve unspecified defaults", function()
            config.setup({
                terminal = { width = 0.5 },
            })
            assert.are.equal("native", config.get("terminal.provider"))
        end)
    end)

    describe("get()", function()
        it("should return full config when no path specified", function()
            local full = config.get()
            assert.is_table(full)
            assert.is_table(full.terminal)
        end)

        it("should return nested values with dot notation", function()
            assert.is_string(config.get("terminal.provider"))
            assert.is_number(config.get("terminal.width"))
        end)

        it("should return nil for invalid paths", function()
            assert.is_nil(config.get("nonexistent.path"))
        end)
    end)

    describe("validate()", function()
        it("should accept valid configuration", function()
            local valid, err = config.validate(config.defaults())
            assert.is_true(valid)
            assert.is_nil(err)
        end)

        it("should reject invalid terminal provider", function()
            local cfg = config.defaults()
            cfg.terminal.provider = "invalid"
            local valid, err = config.validate(cfg)
            assert.is_false(valid)
            assert.is_string(err)
        end)
    end)
end)
EOF
        echo -e "${YELLOW}Created sample test: tests/config_spec.lua${NC}"
    fi
}

# Main
main() {
    cd "$PROJECT_ROOT"

    check_dependencies
    ensure_test_files

    if $WATCH; then
        run_watch
    elif $COVERAGE; then
        run_tests_with_coverage
    else
        run_tests
    fi
}

main
