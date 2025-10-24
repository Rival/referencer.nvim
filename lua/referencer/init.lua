local M = {}
local ns = vim.api.nvim_create_namespace("Referencer")
local config = require("referencer.config")

M.enable = false

-- Track current marks by line number: { [bufnr] = { [line] = { text = "...", mark_id = ... } } }
local mark_state = {}

local function set_virtual_text(bufnr, line, text_to_add)
    -- Initialize buffer state if needed
    if not mark_state[bufnr] then
        mark_state[bufnr] = {}
    end

    -- Check if we already have this exact mark
    local current = mark_state[bufnr][line]
    if current and current.text == text_to_add then
        return  -- No change needed
    end

    -- Delete old mark if it exists
    if current and current.mark_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, current.mark_id)
    end

    -- Create new mark
    local virt_texts = {{ text_to_add, config.get_hl_group() }}
    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
        virt_text = virt_texts,
        virt_text_pos = config.options.virt_text_pos,
        hl_mode = "combine",
    })

    if ok then
        mark_state[bufnr][line] = {
            text = text_to_add,
            mark_id = mark_id
        }
    end
end

local function remove_virtual_text(bufnr, line)
    if not mark_state[bufnr] or not mark_state[bufnr][line] then
        return
    end

    local current = mark_state[bufnr][line]
    if current.mark_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, current.mark_id)
    end
    mark_state[bufnr][line] = nil
end

local client_cache = {}  -- { [client_id] = boolean }

local function is_client_supported(client)
    -- Check cache first
    if client_cache[client.id] ~= nil then
        return client_cache[client.id]
    end

    -- Check capabilities
    if not client:supports_method("textDocument/documentSymbol") then
        client_cache[client.id] = false
        return false
    end

    if not client:supports_method("textDocument/references") then
        client_cache[client.id] = false
        return false
    end

    -- Check whitelist
    local servers = config.options.lsp_servers
    if servers and not vim.tbl_isempty(servers) then
        if not vim.tbl_contains(servers, client.name) then
            client_cache[client.id] = false
            return false
        end
    end

    -- Client is supported
    client_cache[client.id] = true
    return true
end

function M.show_all(client)
    M.enable = true
    if not client then return end
    if not is_client_supported(client) then
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    
    -- Track which lines we're updating in this pass
    local updated_lines = {}
    
    vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", {
        textDocument = vim.lsp.util.make_text_document_params(),
    }, function(_, result, _, _)
            if not result then return end

            local params = {
                textDocument = vim.lsp.util.make_text_document_params(),
                position = nil,
                context = { includeDeclaration = true },
            }

            local function process(symbols)
                for _, sym in ipairs(symbols) do
                    if vim.tbl_contains(config.options.kinds, sym.kind) then
                        local pos = sym.selectionRange.start
                        local line = pos.line

                        params.position = pos
                        updated_lines[line] = true

                        client:request("textDocument/references", params, function(_, refs)
                            if not refs or #refs == 0 then 
                                -- Remove mark if it exists for symbols with no references
                                if not config.options.show_no_reference then
                                    vim.schedule(function()
                                        remove_virtual_text(bufnr, line)
                                    end)
                                end
                                return 
                            end
                            
                            local refsCount = #refs - 1
                            if not config.options.show_no_reference and refsCount == 0 then
                                vim.schedule(function()
                                    remove_virtual_text(bufnr, line)
                                end)
                                return
                            end

                            local msg = string.format(config.options.format, refsCount)
                            vim.schedule(function()
                                set_virtual_text(bufnr, line, msg)
                            end)
                        end, bufnr)
                    end
                    if sym.children then
                        process(sym.children)
                    end
                end
            end

            process(result)
            
            -- Clean up marks for lines that no longer have symbols
            vim.schedule(function()
                if mark_state[bufnr] then
                    for line, _ in pairs(mark_state[bufnr]) do
                        if not updated_lines[line] then
                            remove_virtual_text(bufnr, line)
                        end
                    end
                end
            end)
        end)
end

function M.delete_all()
    M.enable = false
    local bufnr = vim.api.nvim_get_current_buf()
    
    -- Clear our tracking state
    if mark_state[bufnr] then
        mark_state[bufnr] = nil
    end
    
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

function M.toggle()
    if M.enable then
        M.delete_all()
    else
        local bufnr = vim.api.nvim_get_current_buf()
        local clients = vim.lsp.get_clients({ bufnr = bufnr })
        for _, v in ipairs(clients) do
            M.show_all(v)
        end
    end
end

function M.update()
    if M.enable then
        -- Don't delete all, just refresh
        local bufnr = vim.api.nvim_get_current_buf()
        local clients = vim.lsp.get_clients({ bufnr = bufnr })
        for _, v in ipairs(clients) do
            M.show_all(v)
        end
    end
end

-- TODO change to API debounce when they are able to come to agreement
-- https://github.com/neovim/neovim/issues/33179
function M.debounce(fn, delay)
  local timer = nil
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
      timer = nil
    end

    timer = vim.defer_fn(function()
      fn(unpack(args))
      timer = nil
    end, delay)
  end
end

function M.setup(user_opts)
    client_cache = {}
    mark_state = {}
    config.setup(user_opts)

    vim.api.nvim_create_user_command("ReferencerToggle", M.toggle, {})
    vim.api.nvim_create_user_command("ReferencerUpdate", M.update, {})
    
    -- Clean up mark state when buffers are deleted
    vim.api.nvim_create_autocmd("BufDelete", {
        callback = function(args)
            mark_state[args.buf] = nil
        end
    })
end

return M
