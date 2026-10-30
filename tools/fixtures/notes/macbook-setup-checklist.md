# new macbook setup checklist

for when i inevitably get a new one / wipe

## system
- [ ] sign in apple id, turn OFF icloud desktop & documents
- [ ] trackpad: tap to click, tracking speed 8/10
- [ ] keyboard: key repeat fastest, delay shortest, caps lock → escape
- [ ] dock: autohide, remove everything, no recents
- [ ] `defaults write com.apple.dock autohide-delay -float 0; killall Dock`
- [ ] finder: show path bar, show extensions, default to ~/Developer
- [ ] `defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false`
- [ ] screenshots → ~/Screenshots: `defaults write com.apple.screencapture location ~/Screenshots`
- [ ] filevault on

## install
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew bundle --file ~/dotfiles/Brewfile
```
Brewfile highlights: ghostty, raycast, 1password, orbstack, tailscale, neovim, tmux, fzf, ripgrep, fd, eza, bat, lazygit, jq, gh, mise, obs, figma

## dotfiles
- [ ] `git clone git@github.com:example-user/dotfiles ~/dotfiles && cd ~/dotfiles && stow zsh tmux nvim ghostty git`
- [ ] gpg / ssh keys from 1password ssh agent
- [ ] `gh auth login`
- [ ] `mise use -g node@lts bun@latest go@latest`
- [ ] xcode from the app store, then `sudo xcodebuild -license accept`

## apps to sign into
- [ ] raycast (import settings file), 1password, slack, discord, notion, figma, adobe CC
- [ ] tailscale → approve in admin console
- [ ] obs scenes from the backup

## after
- [ ] time machine to the nas
- [ ] restore the launchd backup agent
- [ ] check the global hotkeys don't conflict (raycast vs notes app)
- [ ] login items: only raycast, 1password, tailscale
