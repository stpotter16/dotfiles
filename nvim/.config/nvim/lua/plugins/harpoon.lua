return {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    config = function()
        local harpoon = require "harpoon"
        harpoon:setup()

        vim.keymap.set("n", "<leader>a", function()
            harpoon:list():add()
        end)

        vim.keymap.set("n", "<leader>j", function()
            harpoon.ui:toggle_quick_menu(harpoon:list())
        end)

        vim.keymap.set("n", "<C-h>", function()
            harpoon:list().select(1)
        end)

        vim.keymap.set("n", "<C-n>", function()
            harpoon:list().select(2)
        end)

        vim.keymap.set("n", "<C-i>", function()
            harpoon:list().select(3)
        end)
    end,
}
