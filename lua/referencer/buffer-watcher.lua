local bit = require("bit")
local config = require("referencer.config")
local SymbolsWatcher = require("referencer.symbols-watcher.symbols-watcher")

---@class BufferLspWatcher
---@field line_states table<number, table>
---@field buffer_id number
---@field adorners SymbolAdorner[]
---@field pending_requests table
---@field lsp_clients vim.lsp.Client[]
---@field is_active boolean
---@field option_show_no_reference boolean
---@field kinds_mask integer
---@field last_update number
---@field symbols_watcher SymbolsWatcher
local BufferLspWatcher = {}
BufferLspWatcher.__index = BufferLspWatcher

---@param kinds_mask integer
---@return BufferLspWatcher watcher
function BufferLspWatcher.new(buffer, ns, opts, kinds_mask)
    print("Watcher created:" .. vim.inspect(kinds_mask))
    return setmetatable({
        -- These are INSTANCE fields (unique per object)
        line_states = {},
        buffer_id = buffer,
        mode = nil,
        adorners = {},
        pending_requests = {},
        lsp_clients = {},
        is_active = false,
        option_show_no_reference = opts.show_no_reference,
        kinds_mask = kinds_mask,
        symbols_watcher = SymbolsWatcher.new(buffer, ns),
        last_update = 0,
    }, BufferLspWatcher)
end

local function is_request_valid(bufnr, cancelled, start_changedtick)
    return not cancelled
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_changedtick(bufnr) == start_changedtick
end

---@param adorner SymbolAdorner
---@param opts SymbolAdornerOpions
function BufferLspWatcher:add_adorner(adorner, opts, kinds_mask)
    table.insert(self.adorners, adorner)
    adorner:init(opts, #self.adorners, kinds_mask)
    print("adorner added:" .. vim.inspect(opts) .. "mask:" .. kinds_mask)
end

function BufferLspWatcher:add_client(client)
    table.insert(self.lsp_clients, client)
    self:actualize_all_lsps(false)
end

function BufferLspWatcher:remove_client(client)
    for i = 1, #self.lsp_clients do
        if self.lsp_clients[i] == client then
            table.remove(self.lsp_clients, i)
            return
        end
    end
    if #self.lsp_clients > 0 then
        self:actualize_all_lsps(false)
    end
end

---@param client vim.lsp.Client
function BufferLspWatcher:actualize_from_client(client, start_changedtick, cancelled_ref, request_ids, on_complete)
    local bufnr = self.buffer_id
    local pending_refs = 0  -- Track reference requests for THIS client

    local function check_client_completion()
        if pending_refs == 0 then
            on_complete()  -- This client is done
        end
    end

    -- Make ONE documentSymbol request
    local success, req_id = client:request("textDocument/documentSymbol", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
    }, function(_, result, _, _)
            -- Check if cancelled
            if cancelled_ref[1] then
                on_complete()
                return
            end

            -- Validate buffer state
            if not is_request_valid(bufnr, cancelled_ref[1], start_changedtick) then
                on_complete()
                return
            end

            -- No symbols found
            if not result then
                on_complete()
                return
            end

            -- Process symbols and make reference requests
            local params = {
                textDocument = vim.lsp.util.make_text_document_params(bufnr),
                position = nil,
                context = { includeDeclaration = true },
            }

            ---@param symbols lsp.DocumentSymbol[]
            local function process(symbols)
                for _, sym in ipairs(symbols) do
                    local kind_bit = bit.lshift(1, sym.kind - 1) --- also will be usefull to check this later in adorners, -1 because we start at File = 1  
                    if bit.band(kind_bit, self.kinds_mask) ~= 0 then

                        pending_refs = pending_refs + 1

                        local pos = sym.selectionRange.start
                        params.position = pos
                        local ref_success, ref_req_id = client:request("textDocument/references", params, function(_, refs)
                            if cancelled_ref[1] then
                                pending_refs = pending_refs - 1
                                check_client_completion()
                                return
                            end

                            if not is_request_valid(bufnr, cancelled_ref[1], start_changedtick) then
                                pending_refs = pending_refs - 1
                                check_client_completion()
                                return
                            end

                            if refs then
                                local refsCount = #refs > 0 and (#refs - 1) or 0

                                if self.option_show_no_reference or refsCount > 0 then
                                    ---@type SymbolData
                                    local symbol_data = {
                                        refs = refs,
                                        sym = sym,
                                        kind = kind_bit
                                    }
                                    self.symbols_watcher:set_data_for_symbol(symbol_data)
                                end
                            end

                            pending_refs = pending_refs - 1
                            check_client_completion()
                        end, bufnr)

                        if ref_success and ref_req_id then
                            table.insert(request_ids, ref_req_id)
                        else
                            pending_refs = pending_refs - 1
                        end
                    end

                    if sym.children then
                        process(sym.children)
                    end
                end
            end

            process(result)

            -- If no reference requests were made, complete immediately
            check_client_completion()
        end, bufnr)

    if success and req_id then
        table.insert(request_ids, req_id)
    else
        on_complete()
    end
end

function BufferLspWatcher:actualize_all_lsps(dry_run)
    if dry_run then
        print("===Dry run start")
        self.symbols_watcher:actualize_buffer_change()
        print("===Dry run end")
        return  -- Don't start LSP requests
    end

    local bufnr = self.buffer_id
    local start_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

    -- Cancel existing
    if self.pending_requests and self.pending_requests.cancel_fn then
        self.pending_requests.cancel_fn()
    end

    local pending_requests = {}
    self.pending_requests = pending_requests

    local request_ids = {}
    local cancelled_ref = {false}  -- Use table so it's mutable
    local pending_clients = #self.lsp_clients

    local cancel_fn = function()
        cancelled_ref[1] = true
        for _, req_id in ipairs(request_ids) do
            for _, client in ipairs(self.lsp_clients) do
                pcall(function() client:cancel_request(req_id) end)
            end
        end
        self.pending_requests = nil
        print("===Actualize cancelled, changetick:" .. start_changedtick)
        self.symbols_watcher:cancel_lsp_actualization()
    end

    pending_requests.cancel_fn = cancel_fn

    -- Start actualization ONCE
    print("===Actualize start, changetick:" .. start_changedtick)
    self.symbols_watcher:lsp_actualize()

    local function check_all_completion()
        if pending_clients == 0 and not cancelled_ref[1] then
            self.pending_requests = nil
            vim.schedule(function()
                print("===Actualize end, changetick:" .. start_changedtick)
                self.symbols_watcher:finish_lsp_actualization()
            end)
        end
    end

    -- Request from all clients
    for _, client in ipairs(self.lsp_clients) do
        self:actualize_from_client(client, start_changedtick, cancelled_ref, request_ids, function()
            pending_clients = pending_clients - 1
            check_all_completion()
        end)
    end
end

function BufferLspWatcher:destroy()
    local bufnr = self.buffer_id

    -- Clear using both modes to be safe
    self.symbols_watcher:clear_buffer()
end

return BufferLspWatcher
