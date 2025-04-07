return {
    "NeogitOrg/neogit",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "sindrets/diffview.nvim",
        "nvim-telescope/telescope.nvim",
    },
    config = function()
        local neogit = require("neogit")
        neogit.setup {}
        vim.keymap.set("n", "<leader>gs", "<cmd>Neogit<cr>")
    end,
}
