local nnoremap = require("spotter.keymap").nnoremap

-- nnetrew nonsense
nnoremap("<leader>pv", "<cmd>Ex<cr>")

-- fun with telescope
nnoremap("<leader>ff", "<cmd>Telescope find_files<cr>")
nnoremap("<leader>fg", "<cmd>Telescope live_grep<cr>")
nnoremap("<leader>fs", "<cmd>Telescope grep_string<cr>")
nnoremap("<leader>fb", "<cmd>Telescope buffers<cr>")
nnoremap("<leader>ch", "<cmd>Telescope command_history<cr>")

-- undotree
nnoremap("<leader>ut", "<cmd>UndoTreeToggle<cr>")

-- neogit
nnoremap("<leader>gs", "<cmd>Neogit<cr>")
