# Prism.nvim shell helpers
# Add to your .bashrc or .zshrc:
#   source /path/to/prism.nvim/shell/prism.sh

# Usage: Set CLAUDE_ARGS before opening nvim
#   CLAUDE_ARGS="--continue" nvim
#   CLAUDE_ARGS="--model opus --continue" nvim file.py

# nvc [claude-flags...] [files...] - Open nvim with Claude flags
# Flags (--*) go to Claude, everything else to nvim
nvc() {
  local claude_args=""
  local files=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*)
        if [[ "$2" && ! "$2" =~ ^-- ]]; then
          claude_args+="$1 $2 "
          shift 2
        else
          claude_args+="$1 "
          shift
        fi
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done
  CLAUDE_ARGS="${claude_args% }" nvim "${files[@]}"
}
alias nvco='nvc --model opus'
alias nvcs='nvc --model sonnet'
alias nvch='nvc --model haiku'

# Open with specific model
# Usage: nvim-model opus [files...]
nvim-model() {
  local model="$1"
  shift
  CLAUDE_ARGS="--model $model" nvim "$@"
}

# Continue last session
# Usage: nvim-continue [files...]
nvim-continue() {
  CLAUDE_ARGS="--continue" nvim "$@"
}

# Resume a specific session
# Usage: nvim-resume <session-id> [files...]
nvim-resume() {
  local session="$1"
  shift
  CLAUDE_ARGS="--resume $session" nvim "$@"
}

# Full combo: model + continue + chrome
# Usage: nvim-full opus [files...]
nvim-full() {
  local model="${1:-opus}"
  shift
  CLAUDE_ARGS="--model $model --continue --chrome" nvim "$@"
}
