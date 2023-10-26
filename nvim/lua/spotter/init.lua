require("spotter.set")
require("spotter.remap")
local neogit = require("neogit")
neogit.setup {}

local augroup = vim.api.nvim_create_augroup
local spotterGroup = augroup('spotter', {})

local autocmd = vim.api.nvim_create_autocmd

autocmd({"BufWritePre"}, {
    group = spotterGroup,
    pattern = "*",
    command = [[s/\s\+$//e]],
})
