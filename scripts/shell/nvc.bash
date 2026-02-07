# Prism.nvim helpers
nvc() {
  local claude_args=""
  while [[ $# -gt 0 && "$1" == -* ]]; do
    if [[ "$1" == "--model" || "$1" == "--allowedTools" || "$1" == "--disallowedTools" ]]; then
      claude_args="$claude_args $1 $2"
      shift 2
    else
      claude_args="$claude_args $1"
      shift
    fi
  done
  CLAUDE_ARGS="$claude_args" nvim "$@"
}
alias nvco='nvc --model opus'
