vim.opt.guicursor = ""

vim.opt.errorbells = false

vim.opt.nu = true
vim.opt.relativenumber = true

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

vim.opt.hlsearch = false
vim.opt.incsearch = true

vim.opt.smartindent = true

vim.opt.wrap = false
vim.opt.scrolloff = 8
vim.opt.signcolumn = "yes"
vim.api.nvim_set_option_value("colorcolumn", "80", {})

vim.g.mapleader = " "

vim.opt.undodir = os.getenv("HOME") .. "/.vim/undodir//"
vim.opt.undofile = true
