# zshrc aliases

```zsh
# git
alias gs='git status -sb'
alias ga='git add'
alias gc='git commit -v'
alias gca='git commit --amend --no-edit'
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gl='git log --oneline --graph --decorate -20'
alias gco='git checkout'
alias gsw='git switch'
alias gwip='git add -A && git commit -m "wip" --no-verify'

# nav
alias dev='cd ~/Developer'
alias ..='cd ..'
alias ...='cd ../..'
alias ls='eza --group-directories-first'
alias ll='eza -la --git --group-directories-first'
alias tree='eza --tree --level=2 --git-ignore'

# tools
alias v='nvim'
alias cat='bat --paging=never'
alias lg='lazygit'
alias p='pnpm'
alias b='bun'
alias c='claude'
alias k='kubectl'
alias dc='docker compose'
alias ts='tailscale'

# misc
alias reload='source ~/.zshrc'
alias myip='curl -s https://ipinfo.io/ip'
alias ports='lsof -iTCP -sTCP:LISTEN -n -P'
alias flushdns='sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder'
alias cleanxc='rm -rf ~/Library/Developer/Xcode/DerivedData/*'
alias nm='find . -name node_modules -type d -prune -exec rm -rf {} +'

# fns
mkcd() { mkdir -p "$1" && cd "$1" }
killport() { lsof -ti tcp:"$1" | xargs kill -9 }
```

- `gpf` saved me at least twice
- eza > exa (exa is unmaintained)
- `ports` is the one i use most
