return {
    "mbbill/undotree",

    config = function() 
        vim.keymap.set('n', '<leader>ut', '<cmd>UndotreeToggle<cr>')
        vim.keymap.set('n', '<leader>uf', '<cmd>UndotreeFocus<cr>')
    end
}
