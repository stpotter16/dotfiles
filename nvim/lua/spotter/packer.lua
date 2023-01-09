-- This file can be loaded by calling `lua require('plugins')` from your init.vim

-- Only required if you have packer configured as `opt`
vim.cmd [[packadd packer.nvim]]

return require('packer').startup(function(use)
  -- Packer can manage itself
  use 'wbthomason/packer.nvim'

  use {
      'nvim-telescope/telescope.nvim', branch='0.1.x',
      requires = { {'nvim-lua/plenary.nvim'} }
  }

  -- Come back and switch to rose-pine?
  use 'folke/tokyonight.nvim'

  use {
      'nvim-treesitter/nvim-treesitter',
      run = function() require('nvim-treesitter.install').update({ with_sync = true }) end,
  }
  use('nvim-treesitter/playground')

  use 'neovim/nvim-lspconfig'

  use 'mbbill/undotree'

  use 'TimUntersberger/neogit'
  end)
