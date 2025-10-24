local M = {}

M.options = {
    enable = false,
    format = "  %d reference(s)",
    show_no_reference = true,
    kinds = { 5, 6, 8, 12, 13, 14, 23, },
    hl_group = "Comment",
    color = nil,
    virt_text_pos = "eol",
    pattern = nil,
    lsp_servers = {},
    auto_update = "change",  -- "none", "save", "change"
    update_debunce_time = 1000,  -- how logn to wait after text update
}

local hl_group_from_color = nil

function M.setup(user_opts)
    M.options = vim.tbl_deep_extend("force", M.options, user_opts or {})

    if M.options.color then
        hl_group_from_color = "ReferencerCustomColor"
        vim.api.nvim_set_hl(0, hl_group_from_color, { fg = M.options.color })
    end

    local referencer = require("referencer");
    local group = vim.api.nvim_create_augroup("Referencer", { clear = true })

    if M.options.enable then
        vim.api.nvim_create_autocmd("LspAttach", {
            pattern = M.options.pattern,
            group = group,
            callback = function(ev)
                local client = vim.lsp.get_client_by_id(ev.data.client_id)
                referencer.show_all(client)
            end,
        })
    end

    vim.api.nvim_create_autocmd("LspDetach", {
        callback = function(args)
            referencer.client_cache[args.data.client_id] = nil
        end,
    })

    if M.options.auto_update == "save" then
        vim.api.nvim_create_autocmd("BufWritePost", {
            group = group,
            callback = function()
                referencer.update()
            end,
        })
    elseif M.options.auto_update == "change" then
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = group,
            callback = function()
                referencer.debounce(referencer.update(), M.options.update_debunce_time)
            end,
        })
    end
end

function M.get_hl_group()
    return hl_group_from_color or M.options.hl_group
end

return M
