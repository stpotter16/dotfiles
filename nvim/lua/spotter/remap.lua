local nnoremap = require("spotter.keymap").nnoremap

vim.g.mapleader = " "

-- Evenutally, can use the vim.cmd.Ex syntax (post 0.8.0)...or just build from scratch
vim.keymap.set("n", "<leader>pv", "<cmd>Ex<cr>")

