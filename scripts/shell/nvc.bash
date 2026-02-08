# Prism.nvim helpers
nvc() {
  local claude_args=""
  local env_vars=""

  # Capture environment variable assignments (VAR=value)
  while [[ $# -gt 0 && "$1" == *=* && "$1" != --* ]]; do
    env_vars="$env_vars $1"
    shift
  done

  # Capture Claude flags
  while [[ $# -gt 0 && "$1" == -* ]]; do
    # Two-arg flags
    if [[ "$1" == "--model" || "$1" == "--allowedTools" || "$1" == "--disallowedTools" || \
          "$1" == "--permission-mode" || "$1" == "--max-turns" ]]; then
      claude_args="$claude_args $1 $2"
      shift 2
    else
      # Single-arg flags (--continue, --dangerously-skip-permissions, etc.)
      claude_args="$claude_args $1"
      shift
    fi
  done

  # Export env vars and run nvim with CLAUDE_ARGS
  eval "$env_vars CLAUDE_ARGS=\"$claude_args\" nvim \"\$@\""
}
alias nvco='nvc --model claude-opus-4-5'
alias nvcs='nvc IS_SANDBOX=1 --dangerously-skip-permissions'
