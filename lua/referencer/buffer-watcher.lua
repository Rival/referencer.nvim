local bit = require("bit")
local config = require("referencer.config")
local utils = require("referencer.utils")
local SymbolsWatcher = require("referencer.symbols-watcher.symbols-watcher")
local logger = require("referencer.logger").for_module("buffer_watcher")

---@class CachedSymbol : {[1]: lsp.DocumentSymbol, [2]: boolean}
---Tuple containing:
--- [1]: LSP DocumentSymbol
--- [2]: boolean - true if references have been queried for this symbol at current tick

---@class BufferLspWatcher
---@field line_states table<number, table>
---@field buffer_id number
---@field adorners SymbolAdorner[]
---@field viewport? any Viewport instance (injected from init.lua if enabled)
---@field pending_requests table
---@field lsp_clients vim.lsp.Client[]
---@field is_active boolean
---@field option_show_no_reference boolean
---@field kinds_mask integer
---@field last_update number
---@field symbols_watcher SymbolsWatcher
---@field symbol_cache_tick integer
---@field lsp_symbol_cache CachedSymbol[]
local BufferLspWatcher = {}
BufferLspWatcher.__index = BufferLspWatcher

---@param kinds_mask integer
---@return BufferLspWatcher watcher
function BufferLspWatcher.new(buffer, ns, opts, kinds_mask)
    logger.debug("Watcher created for buffer %d: mask=%d", buffer, kinds_mask)
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
        symbol_cache_tick = 0,
        symbol_cache = nil

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
    logger.info("Adorner added: opts=%s mask=%d", vim.inspect(opts), kinds_mask)
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
function BufferLspWatcher:test_query(client, line, col)
    -- Correct way (what vim.lsp.buf.references() does internally)
    local params = vim.lsp.util.make_position_params()
    params.context = { includeDeclaration = true }

    client:request("textDocument/references", params, function(_, refs)
        logger.debug("Test query got %d references", #refs)
    end)


end

---Fetches references for symbols from a single LSP client
---
---This method implements a two-phase approach to minimize LSP requests:
---1. PHASE 1: documentSymbol - get all symbols in file (cached per changedtick)
---2. PHASE 2: textDocument/references - query references only for visible symbols
---
---Within the same changedtick, symbols are marked as "queried" to prevent duplicate requests
---when scrolling multiple times (e.g., scroll down, scroll up, scroll down again).
---
---@param client vim.lsp.Client The LSP client to query
---@param start_changedtick integer Buffer changedtick when actualization started
---@param cancelled_ref table Reference to cancellation flag {[1]=boolean}
---@param request_ids table Array to store LSP request IDs for cancellation
---@param on_complete function Callback when this client finishes all requests
function BufferLspWatcher:actualize_from_client(client, start_changedtick, cancelled_ref, request_ids, on_complete)
    local bufnr = self.buffer_id
    local pending_refs = 0  -- Track pending reference requests for THIS client

    -- Called when all reference requests for this client complete
    local function check_client_completion()
        if pending_refs == 0 then
            on_complete()  -- Signal that this client is done
        end
    end

    -- VIEWPORT OPTIMIZATION: Only query references for visible symbols
    -- Reduces LSP traffic by skipping off-screen symbols (they can be queried later when scrolled into view)
    local viewport_range = nil
    if self.viewport and self.viewport.enabled then
        viewport_range = self.viewport:get_visible_range()
        logger.debug("Viewport filtering enabled: range=[%d-%d]", viewport_range.expanded_topline, viewport_range.expanded_botline)
    end

    ---PHASE 2: Process symbols and query references
    ---
    ---Iterates through cached symbols and queries references for each visible symbol.
    ---Uses two optimization strategies:
    ---1. Viewport filtering - skip off-screen symbols
    ---2. Query flag - skip symbols already queried at this changedtick
    ---
    ---@param cached_symbols CachedSymbol[] Array of {symbol, queried_flag} tuples
    local function process_symbols(cached_symbols)
        for _, cached_symbol in ipairs(cached_symbols) do
            -- Unpack CachedSymbol tuple: [1]=DocumentSymbol, [2]=queried flag
            ---@type lsp.DocumentSymbol
            local sym = cached_symbol[1]
            ---@type boolean
            local queried = cached_symbol[2]

            local line = sym.selectionRange.start.line

            -- OPTIMIZATION 1: Skip off-screen symbols
            -- They'll be queried when scrolled into view
            if viewport_range and not self.viewport:is_line_in_range(line, viewport_range) then
                logger.debug("Symbol off-screen, skipping LSP request: line=%d kind=%d", line, sym.kind)
                goto continue
            end

            -- OPTIMIZATION 2: Skip already-queried symbols
            -- Prevents duplicate requests when scrolling multiple times within same changedtick
            -- Example: Scroll down (query lines 100-200), scroll back up (lines 100-150 already queried!)
            if queried then
                logger.debug("Symbol already queried at tick %d, skipping: line=%d col=%d", start_changedtick, line, sym.selectionRange["end"].character - 1)
                goto continue
            end

            -- Make async LSP reference request for this symbol
            pending_refs = pending_refs + 1

            -- Query at end of symbol name (most accurate for references)
            local pos = {
                line = sym.selectionRange["end"].line,
                character = sym.selectionRange["end"].character - 1,  -- Last char of symbol
            }

            local params = {
                textDocument = vim.lsp.util.make_text_document_params(bufnr),
                position = pos,
                context = { includeDeclaration = true },  -- Include the symbol definition itself
            }

            -- ASYNC CALLBACK: Process references when they arrive
            local ref_success, ref_req_id = client:request("textDocument/references", params, function(_, refs)
                -- Early exit if cancelled (user made new changes)
                if cancelled_ref[1] then
                    pending_refs = pending_refs - 1
                    check_client_completion()
                    return
                end

                -- Early exit if buffer changed or was deleted
                if not is_request_valid(bufnr, cancelled_ref[1], start_changedtick) then
                    pending_refs = pending_refs - 1
                    check_client_completion()
                    return
                end

                if refs then
                    -- CRITICAL: Mark symbol as queried to prevent duplicate requests on next scroll
                    -- This flag persists until changedtick changes (buffer edited)
                    cached_symbol[2] = true
                    logger.debug("Symbol marked as queried: line=%d col=%d refs=%d tick=%d", pos.line, pos.character, #refs - 1, start_changedtick)

                    -- LSP returns references including the declaration, so subtract 1 for display
                    local refsCount = #refs > 0 and (#refs - 1) or 0

                    -- Only create SymbolInfo if refs exist OR user wants to see "0 references"
                    if self.option_show_no_reference or refsCount > 0 then
                        local kind_bit = bit.lshift(1, sym.kind - 1)  -- Convert kind to bitmask for adorner filtering
                        ---@type SymbolData
                        local symbol_data = {
                            refs = refs,
                            sym = sym,
                            kind = kind_bit
                        }
                        -- Pass to SymbolsWatcher which creates SymbolInfo and triggers adorner updates
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

            -- No need to process children - already flattened in cache!

            ::continue::
        end
    end

    -- ====================================================================
    -- PHASE 1: Get document symbols (cached per changedtick)
    -- ====================================================================
    -- Cache miss: Need to fetch symbols from LSP
    -- Cache hit: Reuse existing symbols (see else branch below)
    if (self.symbol_cache_tick ~= start_changedtick) then
        logger.debug("Symbol cache MISS (tick %d != %d) - requesting documentSymbol", self.symbol_cache_tick, start_changedtick)

        -- Request all symbols in the document
        -- This is expensive but only done ONCE per changedtick
        local success, req_id = client:request("textDocument/documentSymbol", {
            textDocument = vim.lsp.util.make_text_document_params(bufnr),
        }, function(_, result, _, _)
                -- Early exit checks
                if cancelled_ref[1] then
                    on_complete()
                    return
                end

                if not is_request_valid(bufnr, cancelled_ref[1], start_changedtick) then
                    on_complete()
                    return
                end

                if not result then
                    on_complete()
                    return
                end

                -- Populate cache with flattened symbol list
                self.symbol_cache_tick = start_changedtick
                self.lsp_symbol_cache = {}

                -- Flatten hierarchical symbol tree into flat list
                -- Why flatten? Performance optimization - avoids recursive wrapping on every scroll
                -- Children are flattened ONCE here instead of being wrapped on EVERY process_symbols call
                local function flatten_symbols(symbols)
                    for _, sym in ipairs(symbols) do
                        local kind_bit = bit.lshift(1, sym.kind - 1)

                        -- Filter: Only include symbols matching kind mask AND with selectionRange
                        -- LSP servers vary - some don't provide selectionRange for all symbol types
                        if bit.band(kind_bit, self.kinds_mask) ~= 0 and sym.selectionRange then
                            ---@type CachedSymbol
                            -- Store as {symbol, queried_flag} tuple
                            table.insert(self.lsp_symbol_cache, {sym, false})  -- false = not queried yet
                        end

                        -- Recursively flatten children (methods in classes, nested functions, etc.)
                        if sym.children then
                            flatten_symbols(sym.children)
                        end
                    end
                end

                flatten_symbols(result)
                logger.debug("Symbol cache populated: %d symbols at tick %d", #self.lsp_symbol_cache, start_changedtick)

                -- Now process symbols (query references for visible ones)
                process_symbols(self.lsp_symbol_cache)

                -- If no reference requests were made, complete immediately
                check_client_completion()
            end, bufnr)

        if success and req_id then
            table.insert(request_ids, req_id)
        else
            on_complete()
        end
    else
        -- ====================================================================
        -- CACHE HIT: Reuse existing symbol cache
        -- ====================================================================
        -- Same changedtick = buffer unchanged since last query
        -- Symbol cache is still valid, just process it again with current viewport
        --
        -- Example scenario (within same tick):
        --   1. Scroll to lines 0-100   → cache miss, fetch symbols, query refs for 0-100
        --   2. Scroll to lines 50-150  → cache hit! Reuse symbols, query refs for 101-150
        --   3. Scroll back to 0-100    → cache hit! Reuse symbols, 0-100 marked as queried (skip!)
        --
        -- This is where the queried flag optimization shines - prevents re-querying symbols
        -- that were already queried earlier in the same tick
        logger.debug("Symbol cache HIT (tick=%d) - reusing %d cached symbols", start_changedtick, #self.lsp_symbol_cache)
        process_symbols(self.lsp_symbol_cache)

        -- CRITICAL: Wait for reference requests to complete!
        -- Don't call on_complete() immediately - process_symbols makes async requests
        check_client_completion()
    end
end

---@param buffer_changed_run boolean Quick update when buffer changed (without LSP requests)
---@param append? boolean We append data to existing
function BufferLspWatcher:actualize_all_lsps(buffer_changed_run, append)
    append = append or false
    if buffer_changed_run then
        logger.debug("=== Buffer changed run start ===")
        self.symbols_watcher:actualize_buffer_change()
        logger.debug("=== Buffer changed run end ===")
        return  -- Don't start LSP requests
    end

    local bufnr = self.buffer_id
    local start_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

    -- Skip if buffer hasn't changed since last update (prevents duplicate requests)
    -- Exception: force=true for viewport scrolling (buffer unchanged but viewport moved)
    if not append and self.last_update == start_changedtick then
        logger.info("Actualize skipped, changetick unchanged: %d", start_changedtick)
        return
    end

    -- Note: symbol_cache with queried flags is automatically cleared when changedtick changes
    -- (new documentSymbol request creates fresh cache with all flags reset to false)

    -- Cancel existing requests (user made new changes before previous request completed)
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
        logger.info("Actualize cancelled, changetick: %d", start_changedtick)
        self.symbols_watcher:cancel_lsp_actualization()
    end

    pending_requests.cancel_fn = cancel_fn

    local function check_all_completion()
        if pending_clients == 0 and not cancelled_ref[1] then
            self.pending_requests = nil
            -- Update last changedtick to prevent duplicate requests
            self.last_update = start_changedtick
            vim.schedule(function()
                logger.info("=== Actualize end, changetick: %d ===", start_changedtick)
                self.symbols_watcher:finish_lsp_actualization()
            end)
        end
    end

    if append then
        logger.info("=== Actualize append start, changetick: %d ===", start_changedtick)
        self.symbols_watcher:lsp_actualize_append(start_changedtick)
    else
        -- Start actualization ONCE
        logger.info("=== Actualize start, changetick: %d ===", start_changedtick)
        self.symbols_watcher:lsp_actualize(start_changedtick)
    end

    -- Request from all clients
    for _, client in ipairs(self.lsp_clients) do
        self:actualize_from_client(client, start_changedtick, cancelled_ref, request_ids, function()
            pending_clients = pending_clients - 1
            check_all_completion()
        end)
    end
end

---@param line integer
---@param col integer
function BufferLspWatcher:inspect_position(line, col)
    for i, adorner in ipairs(self.adorners) do
        adorner:inspect_position(line, col)
    end
end

function BufferLspWatcher:destroy()
    local bufnr = self.buffer_id

    -- Clear using both modes to be safe
    self.symbols_watcher:clear_buffer()
end

return BufferLspWatcher
