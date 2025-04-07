vim.api.nvim_create_autocmd("BufWritePre", {
    group = vim.api.nvim_create_augroup("custom-line-trim", {}),
    pattern = "*",
    command = [[s/\s\+$//e]],
})
