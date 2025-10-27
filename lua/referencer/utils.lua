local M = {}

-- Create a unique key for a mark based on line and column
function M.make_mark_key(line, col)
    return string.format("%d:%d", line, col)
end

-- Cache for client capabilities
local client_cache = {}

function M.is_client_supported(client, config)
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

function M.clear_client_cache()
    client_cache = {}
end

-- Debounce function for rate limiting
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

return M
