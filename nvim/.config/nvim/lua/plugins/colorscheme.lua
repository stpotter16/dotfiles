return {
  "folke/tokyonight.nvim",
  tag = "v4.14.1",
  lazy = false,
  priority = 1000,
  opts = {},
  config = function()
    vim.cmd [[colorscheme tokyonight-storm]]
  end,
}
