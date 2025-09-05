return {
  {
    name = 'amazonq',
    url = 'https://github.com/awslabs/amazonq.nvim.git',
    config = function()
      local amazonq = require('amazonq').setup({
        ssoStartUrl = 'https://d-90674d607c.awsapps.com/start',
      })
      vim.keymap.set('n', '<leader>q', '<cmd>AmazonQ<cr>', {})
    end
  },
}
