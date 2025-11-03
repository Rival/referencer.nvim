        config = function()
            -- -- load mason-nvim-dap here, after all adapters have been setup
            -- if LazyVim.has("mason-nvim-dap.nvim") then
            --     require("mason-nvim-dap").setup(LazyVim.opts("mason-nvim-dap.nvim"))
            -- end

            -- vim.api.nvim_set_hl(0, "DapStoppedLine", { default = true, link = "Visual" })


            for name,sign in pairs(LazyVim.config.icons.dap) do
                sign = type(sign) == "table" and sign or { sign }
                vim.fn.sign_define(
                    "Dap" .. name,
                    { text = sign[1], texthl = sign[2] or "DiagnosticInfo", linehl = sign[3], numhl = sign[3] }
                )
            end

             local dap = require"dap"
            dap.configurations.lua = { 
                { 
                    type = 'nlua', 
                    request = 'attach',
                    name = "Attach to running Neovim instance",
                }
            }
            --
            vim.keymap.set('n', '<leader>dl', function() 
                require"osv".launch({port = 8086}) 
            end, { noremap = true })

            dap.adapters.nlua = function(callback, config)
                callback({ type = 'server', host = config.host or "127.0.0.1", port = config.port or 8086 })
            end
            require"nvim-dap-ui".setup({})
            --
            -- require("nvim-dap-virtual-text").setup({})
            -- -- setup dap config by VsCode launch.json file
            -- local vscode = require("dap.ext.vscode")
            -- local json = require("plenary.json")
            -- vscode.json_decode = function(str)
            --     return vim.json.decode(json.json_strip_comments(str))
            -- end
            -- vim.api.nvim_create_autocmd({ "FileType" }, {
            --   pattern = "dap-repl",
            --   group = util.augroup("dap_repl"),
            --   callback = function()
            --     require("dap.ext.autocompl").attach()
            --   end,
            -- })
        end,
