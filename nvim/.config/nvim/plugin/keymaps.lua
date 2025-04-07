-- Evenutally, can use the vim.cmd.Ex syntax (post 0.8.0)...or just build from scratch
vim.keymap.set("n", "<leader>pv", "<cmd>Ex<cr>")

-- Let movement drag text in visual mode
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- Keep the cursor centered in the screen while moving
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")

-- Keep cursor centered while searching
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

-- Yank to system buffer
vim.keymap.set("n", "<leader>y", "\"+y")
vim.keymap.set("n", "<leader>Y", "\"+Y")
vim.keymap.set("v", "<leader>y", "\"+y")

-- Add remap of <C-f> to tmux-sessionizer
vim.keymap.set("n", "<C-f>", "<cmd>silent !tmux neww tmux-sessionizer<CR>")

-- Format code -- need to upgrade neovim
-- vim.keymap.set("n", "<leader>f", vim.lsp.buf.format)

-- Delete and keep buffer contents
vim.keymap.set("x", "<leader>P", [["_dP]])

-- Delete to null buffer
vim.keymap.set({"n", "v"}, "<leader>d", [["_d]])
