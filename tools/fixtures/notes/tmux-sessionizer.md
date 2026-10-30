# tmux sessionizer script

fzf over project dirs → attach or create a session. bound to `C-f` in zsh + `prefix f` in tmux

```bash
#!/usr/bin/env bash
if [[ $# -eq 1 ]]; then
  selected=$1
else
  selected=$(find ~/Developer ~/work -mindepth 1 -maxdepth 1 -type d | fzf --height 40% --reverse)
fi
[[ -z $selected ]] && exit 0

name=$(basename "$selected" | tr . _)

if ! tmux has-session -t="$name" 2>/dev/null; then
  tmux new-session -ds "$name" -c "$selected"
  tmux send-keys -t "$name" "nvim ." C-m
  tmux new-window -t "$name" -c "$selected"
fi

if [[ -z $TMUX ]]; then
  tmux attach -t "$name"
else
  tmux switch-client -t "$name"
fi
```
stolen from primeagen, tweaked. lives at `~/.local/bin/tms`
