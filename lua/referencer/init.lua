local M = {}
local config = require("referencer.config")
local utils = require("referencer.utils")
local virtual_lines_mode = require("referencer.virtual-lines-mode")
local inline_mode = require("referencer.inline-mode")

local ns = vim.api.nvim_create_namespace("Referencer")
local group = vim.api.nvim_create_augroup("Referencer", { clear = true })

M.enable = false

local option_show_no_reference = false
local option_kinds = {}
local current_mode = nil

local lsp_clients = {}
local function is_request_valid(bufnr, cancelled, start_changedtick)
    return not cancelled
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_changedtick(bufnr) == start_changedtick
end

function M.get_current_mode()
   return current_mode
end

---@param client vim.lsp.Client
local function actualize_from_lsp(client, bufnr)
    local start_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

    -- Cancel any existing request
    if M.pending_requests[bufnr] and M.pending_requests[bufnr].cancel_fn then
        M.pending_requests[bufnr].cancel_fn()
    end

    -- recreate the pending request entry
    M.pending_requests[bufnr] = {}

    local request_ids = {}
    local cancelled = false
    local pending_refs = 0  -- Track pending reference requests

    local actualization_ctx = nil
    local cancel_fn = function()
        cancelled = true
        for _, req_id in ipairs(request_ids) do
            client:cancel_request(req_id)
        end
        M.pending_requests[bufnr] = nil
        if actualization_ctx then
            current_mode.actualization_cancelled(actualization_ctx, bufnr)
        end
    end

    M.pending_requests[bufnr].cancel_fn = cancel_fn

    -- Function to check if all requests are done
    local function check_completion()
        if pending_refs == 0 and not cancelled then
            -- vim.schedule(function()
                if not cancelled then
                    M.pending_requests[bufnr] = nil
                    vim.schedule(function ()
                    current_mode.actualization_end(actualization_ctx, bufnr)
                    end)
                end
            -- end)
        end
    end

    local success, req_id = client:request("textDocument/documentSymbol", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
    }, function(_, result, _, _)
            if cancelled then return end

            if not vim.api.nvim_buf_is_valid(bufnr) or
                vim.api.nvim_buf_get_changedtick(bufnr) ~= start_changedtick then
                cancel_fn()
                return
            end

            if not result then
                M.pending_requests[bufnr] = nil
                return
            end

            actualization_ctx = current_mode.actualization_start(bufnr)

            local params = {
                textDocument = vim.lsp.util.make_text_document_params(bufnr),
                position = nil,
                context = { includeDeclaration = true },
            }

            local function process(symbols)
                for _, sym in ipairs(symbols) do
                    if vim.tbl_contains(option_kinds, sym.kind) then
                        local pos = sym.selectionRange.start
                        local line = pos.line
                        local col = pos.character

                        params.position = pos

                        pending_refs = pending_refs + 1

                        local ref_success, ref_req_id = client:request("textDocument/references", params, function(_, refs)
                            if cancelled then 
                                pending_refs = pending_refs - 1
                                return 
                            end

                            -- Quick validation check
                            if not is_request_valid(bufnr, false, start_changedtick) then
                                pending_refs = pending_refs - 1
                                cancel_fn()
                                return
                            end

                            -- Only proceed if we have valid refs
                            if not refs then
                                pending_refs = pending_refs - 1
                                check_completion()
                                return
                            end
                            -- Calculate reference count
                            local refsCount = (refs and #refs > 0) and (#refs - 1) or 0
                            --
                            -- -- Should we show this mark?
                            -- if not option_show_no_reference and refsCount == 0 then
                            --     vim.schedule(function()
                            --         if is_request_valid(bufnr, cancelled, start_changedtick) then
                            --             current_mode.remove_virtual_text(bufnr, line, col)
                            --         end
                            --     end)
                            --     pending_refs = pending_refs - 1
                            --     check_completion()
                            --     return
                            -- end

                            -- Show the reference count
                            local symbol_data = {
                                refs = refs,
                                sym = sym
                            }

                            current_mode.set_virtual_text(actualization_ctx, bufnr, line, col, symbol_data)

                            pending_refs = pending_refs - 1
                            check_completion()  -- Check if this was the last one
                        end, bufnr)

                        if ref_success and ref_req_id then
                            table.insert(request_ids, ref_req_id)
                        else
                            -- Request failed to start, decrement counter
                            pending_refs = pending_refs - 1
                        end
                    end
                    if sym.children then
                        process(sym.children)
                    end
                end
            end

            process(result)

            -- Check if there were no reference requests at all (or all completed synchronously)
            check_completion()
        end, bufnr)

    -- Track the initial request ID
    if success and req_id then
        table.insert(request_ids, req_id)
    end
end

local function actualize_all_lsps(bufnr)
    for _, client in ipairs(lsp_clients) do
        actualize_from_lsp(client, bufnr)
    end
end

function M.delete_all()
    M.enable = false
    local bufnr = vim.api.nvim_get_current_buf()

    -- Clear using both modes to be safe
    virtual_lines_mode.clear_buffer(bufnr, ns)
    inline_mode.clear_buffer(bufnr, ns)
end

local function enable()
    local options = config.options
    vim.api.nvim_create_autocmd("LspAttach", {
        pattern = options.pattern,
        group = group,
        callback = function(ev)
            local buffer = ev.buf

            --show all ao attach
            local client = vim.lsp.get_client_by_id(ev.data.client_id)
            if not client or not utils.is_client_supported(client, config) then return end

            table.insert(lsp_clients, client)
            current_mode.init_buffer(buffer)
            actualize_from_lsp(client, buffer)

            --call updates only for specific buffer
            local debounced_update = utils.debounce(function()
                actualize_from_lsp(client, buffer)
            end, options.update_debounce_time)
            if options.auto_update == "change" then

                vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
                    group = group,
                    buffer = buffer,  -- Specific to this buffer
                    callback = debounced_update,
                })
            end

            if options.auto_update == "save" then
                vim.api.nvim_create_autocmd("BufWritePost", {
                    group = group,
                    callback = function(e)
                        actualize_all_lsps(e.buf)
                    end,
                })
            end

            -- Clean up mark state when buffers are deleted
            vim.api.nvim_create_autocmd("BufDelete", {
                group = group,
                callback = function(e)
                    current_mode.clear_buffer(e.buf)
                end
            })
            if config.options.mode == "virtual_line" then
                -- Update virtual lines on horizontal scroll to make them scroll with text
                vim.api.nvim_create_autocmd("WinScrolled", {
                    callback = function()
                        if not M.enable then return end
                        local bufnr = vim.api.nvim_get_current_buf()

                        -- Only update virtual lines mode
                        virtual_lines_mode.update_on_scroll(bufnr, ns)
                    end
                })
            else
            end
        end,
    })

    vim.api.nvim_create_autocmd("LspDetach", {
        callback = function(ev)
            local client = vim.lsp.get_client_by_id(ev.data.client_id)
            if not client or not utils.is_client_supported(client, config) then return end
            lsp_clients = vim.iter(lsp_clients)
                :filter(function(c) return c ~= client end)
                :totable()
            -- Clear client cache when LSP detaches
            utils.clear_client_cache()
        end,
    })
end

local function disable()
    M.enable = false
    M.delete_all()
end

function M.toggle()
    if M.enable then
        disable()
    else
        enable()
        local bufnr = vim.api.nvim_get_current_buf()
        local clients = vim.lsp.get_clients({ bufnr = bufnr })
        for _, v in ipairs(clients) do
            M.actualize_from_lsp(v, bufnr)
        end
    end
end

function M.update()
    if M.enable then
        -- Don't delete all, just refresh
        local bufnr = vim.api.nvim_get_current_buf()
        local clients = vim.lsp.get_clients({ bufnr = bufnr })
        for _, v in ipairs(clients) do
            M.actualize_from_lsp(v, bufnr)
        end
    end
end

function M.setup(user_opts)
    utils.clear_client_cache()
    config.setup(user_opts)

    M.pending_requests = M.pending_requests or {}
    option_show_no_reference = config.options.show_no_reference
    option_kinds = config.options.kinds

    if user_opts.mode == "virtual_line" then
        current_mode = virtual_lines_mode
        -- actualization_start = virtual_lines_mode.a
        -- Update virtual lines on horizontal scroll to make them scroll with text
        vim.api.nvim_create_autocmd("WinScrolled", {
            callback = function()
                if not M.enable then return end
                local bufnr = vim.api.nvim_get_current_buf()
                -- Only update virtual lines mode
                virtual_lines_mode.update_on_scroll(bufnr, ns)
            end
        })
    else
        current_mode = inline_mode
    end

    current_mode.init(user_opts, ns)

    vim.api.nvim_create_user_command("ReferencerToggle", M.toggle, {})
    vim.api.nvim_create_user_command("ReferencerUpdate", M.update, {})

    if (user_opts.enable) then
        M.toggle()
    end
end
return M
