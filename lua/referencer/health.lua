-- lua/referencer/health.lua
local M = {}
local health = vim.health or require("health")

M.check = function()
    health.start("Referencer.nvim")

    -- -- Skip if we're in a special buffer
    -- local buftype = vim.bo.buftype
    -- if buftype ~= "" then
    --     health.info("Checkhealth must be run from a normal buffer")
    --     health.info("Open a file first, then run :checkhealth referencer")
    --     return
    -- end

    local clients = vim.lsp.get_clients()

    if #clients == 0 then
        health.warn("No LSP clients currently active")
        health.info("To test LSP support:")
        health.info("1. Open a file with LSP (e.g., :e test.lua)")
        health.info("2. Run :checkhealth referencer again")
        return
    end
    health.start("LSP Support Check")

    -- Check across all buffers, not just current one
    local clients = vim.lsp.get_clients()

    if #clients == 0 then
        health.warn("No active LSP clients", {
            "Start Neovim with a file that has LSP support",
            "Example: nvim file.lua"
        })
        return
    end

    local has_support = false

    for _, client in ipairs(clients) do
        health.start(string.format("LSP: %s", client.name))

        if client:supports_method("textDocument/documentSymbol") then
            health.ok("Supports document symbols (textDocument/documentSymbol)")
            has_support = true
        else
            health.warn("Does not support document symbols (textDocument/documentSymbol)")
        end

        if client:supports_method("textDocument/references") then
            health.ok("Supports references")
        else
            health.error("Does not support references - required for this plugin!")
        end
    end

    if has_support then
        health.ok("At least one LSP server supports required features")
    end
end

return M
