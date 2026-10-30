# nvim keymaps

```lua
vim.g.mapleader = " "
local map = vim.keymap.set

map("n", "<leader>ff", "<cmd>Telescope find_files<cr>")
map("n", "<leader>fg", "<cmd>Telescope live_grep<cr>")
map("n", "<leader>e", "<cmd>Oil<cr>")
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")
map("v", "J", ":m '>+1<CR>gv=gv")
map("v", "K", ":m '<-2<CR>gv=gv")
map("n", "<leader>y", '"+y')
map("n", "<leader>rn", vim.lsp.buf.rename)
map("n", "gd", vim.lsp.buf.definition)
map("n", "<leader>ca", vim.lsp.buf.code_action)
```
- `<C-h/j/k/l>` handled by vim-tmux-navigator so it moves between nvim splits and tmux panes seamlessly
