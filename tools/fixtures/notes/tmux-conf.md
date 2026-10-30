# tmux.conf

```tmux
# prefix → C-a
unbind C-b
set -g prefix C-a
bind C-a send-prefix

set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g history-limit 50000
set -sg escape-time 0          # nvim esc lag
set -g focus-events on
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-ghostty:RGB"

# splits keep cwd
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

# vim-ish pane nav
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# copy mode
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "pbcopy"

# reload
bind r source-file ~/.tmux.conf \; display "reloaded"

# status bar — minimal, black/white
set -g status-position top
set -g status-style "bg=default,fg=white"
set -g status-left "#[bold]#S "
set -g status-right "#h  %H:%M"
setw -g window-status-current-style "fg=#4DABF7,bold"
set -g pane-active-border-style "fg=#4DABF7"

# plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @continuum-restore 'on'
run '~/.tmux/plugins/tpm/tpm'
```

notes
- `escape-time 0` is the big one for nvim
- RGB override needed for true color in ghostty, check w/ `tmux info | grep RGB`
- resurrect saves to `~/.local/share/tmux/resurrect`, sometimes restores dead panes, meh
- prefix+I to install plugins after adding
