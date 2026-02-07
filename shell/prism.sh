# Prism.nvim shell helpers
# Add to your .bashrc or .zshrc:
#   source /path/to/prism.nvim/shell/prism.sh

# Usage: Set CLAUDE_ARGS before opening nvim
#   CLAUDE_ARGS="--continue" nvim
#   CLAUDE_ARGS="--model opus --continue" nvim file.py

# Convenience aliases
alias nvc='CLAUDE_ARGS="--continue" nvim'
alias nvco='CLAUDE_ARGS="--model opus" nvim'
alias nvcs='CLAUDE_ARGS="--model sonnet" nvim'
alias nvch='CLAUDE_ARGS="--model haiku" nvim'
alias nvcr='CLAUDE_ARGS="--continue --resume" nvim'

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
