require'nvim-treesitter.configs'.setup {
    ensure_installed = { "help", "lua", "rust", "python", "javascript", "typescript" },
    sync_install = false,
    auto_install = false,
    highlight = {
        enable = true,
        additiona_vim_regex_highlighting = false,
    }
}
