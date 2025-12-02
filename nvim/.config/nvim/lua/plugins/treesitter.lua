return {
  "nvim-treesitter/nvim-treesitter",
  tag = "v0.10.0",
  build = ":TSUpdate",
  config = function()
    local configs = require("nvim-treesitter.configs")

    configs.setup({
      ensure_installed = { "lua", "rust", "python", "javascript", "typescript", "html", "go" },
      sync_install = false,
      auto_install = false,
      highlight = {
        enable = true,
        additiona_vim_regex_highlighting = false,
      },
      indent = { enable = true },
    })
  end,
}
