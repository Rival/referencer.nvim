local event = require("referencer.event")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local LineInfo = require("referencer.symbols-watcher.line-info")
local logger = require("referencer.logger").for_module("symbols_watcher")

---@alias FastChangeValidator fun(watcher:SymbolsWatcher, symbol:SymbolInfo, text_add:string):boolean

---@class ActualizationContext
---@field line_states table<integer,LineInfo> line states for buffer
---@field new_mark_infos SymbolInfo | nil marks infos to be created on actualization end

---@class SymbolData
---@field kind integer LSP kind converted to bitmask
---@field sym lsp.DocumentSymbol LSP symbol info
---@field refs lsp.CompletionListCapabilities[] references from LSP

---@class MarkOpts
---@field id? integer Extmark ID (set after creation)
---@field virt_text string[][] Array of [text, hl_group] pairs
---@field virt_text_pos string Position: "eol", "inline", etc.
---@field hl_mode string Highlight mode: "combine", "replace", etc.

---@class LineEventArgs
---@field line_info LineInfo

---@class LineSymbolsChangedEventArgs:LineEventArgs
---@field old_line LineInfo
---@field symbol SymbolInfo


---@class SymbolEventArgs
---@field data SymbolData
---@field symbol SymbolInfo

---@class SymbolDataChangedEventArgs:SymbolEventArgs
---@field status SymbolStatus

---@class SymbolMarkChangedEventArgs
---@field prev_line integer
---@field prev_col integer
---@field prev_end_col integer
---@field symbol SymbolInfo


---@class SymbolsWatcher
---@field buffer integer
---@field namespace integer
---@field is_lsp_actualizing boolean
---@field changetick integer
---@field is_stale boolean
---@field lines table<integer, LineInfo>
---@field fast_change_validator FastChangeValidator
---@field viewport? any Viewport instance (injected from init.lua if enabled)
---@field OnLineCreated Event<LineEventArgs>
---@field OnLineDestroyed Event<LineEventArgs>
---@field OnSymbolMarkChanged Event<SymbolEventArgs>
---@field OnSymbolLineChanged Event<LineSymbolsChangedEventArgs>
---@field OnSymbolDataUpdated Event<SymbolDataChangedEventArgs>
---@field OnSymbolMarkDestroyed Event<SymbolInfo>
---@field new_symbols SymbolInfo[]
---@field OnActualizeBufferChange any
---@field OnActualize any
---@field OnActualizeStart any
---@field OnActualizeEnd Event<any>
---@field OnActualizeCancelled any
local SymbolsWatcher = {}
SymbolsWatcher.__index = SymbolsWatcher


---@enum SymbolStatus
local SymbolStatus = {
    None = 0,
    New = 1,
    SizeChanged = 2,
    BadSize = 3,
}

SymbolsWatcher.SymbolStatus = SymbolStatus

function SymbolsWatcher.new(bufnr, ns)
    local instance = setmetatable({
        lines = {},
        new_symbols = {},
        buffer = bufnr,
        namespace = ns,
        is_actualizing = false,
        changetick = vim.api.nvim_buf_get_changedtick(bufnr),  -- Initialize with current buffer changetick
        is_stale = false,
        OnLineCreated = event.new(),
        OnLineDestroyed = event.new(),
        OnSymbolLineChanged = event.new(),
        OnSymbolMarkChanged = event.new(),
        OnSymbolDataUpdated = event.new(),
        OnSymbolMarkDestroyed = event.new(),
        OnActualizeBufferChange = event.new(),
        OnActualize = event.new(),
        OnActualizeStart = event.new(),
        OnActualizeEnd = event.new(),
        OnActualizeCancelled = event.new(),
        fast_change_validator = function (_watcher, _symbol, added_text)
            -- Characters that definitely are NOT part of identifiers
            local breaks_identifier = {
                [' '] = true,
                ['.'] = true,
                [';'] = true,
                [':'] = true,
                ['/'] = true,
                ['-'] = true,
                ['+'] = true,
                ['*'] = true,
                [','] = true,
                ['\n'] = true,
                ['\t'] = true,
            }

            -- Check every character in the added text
            for i = 1, #added_text do
                local char = added_text:sub(i, i)
                if not breaks_identifier[char] then
                    -- Found a char that might be part of identifier
                    return true
                end
            end

            -- All chars break identifiers - don't mark stale
            return false
        end
    }, SymbolsWatcher)
    return instance
end


function SymbolsWatcher:is_dry()
    return self.is_lsp_actualizing == false
end

---@param symbol SymbolInfo
function SymbolsWatcher.get_symbol_end_col(symbol)
    return symbol[SymbolInfo.CORE].end_col
    -- return symbol[SymbolInfo.SYMBOL_DATA].sym.selectionRange['end'].character or 1
end

---@param mark SymbolInfo
function SymbolsWatcher:create_ext_mark_for_symbol(mark)
    --firts we check validity, mb symbol is bad 
    --f.e. methods can have zero width with dot and ends on next line 0 col

    ---@type MarkCore
    local mark_core = mark[SymbolInfo.CORE]
    if mark_core.col >= mark_core.end_col then
        logger.warn("ext_mark not created - bad size: %s", SymbolInfo.id_pos_to_string(mark))
        --strange, we don't need this
        return
    end
    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, self.buffer, self.namespace,
        mark_core.line,
        mark_core.col,
        mark[SymbolInfo.OPTS])
    if ok then
        SymbolInfo.set_mark_id(mark, mark_id)
        --- we can not set this on first creation, so we had to set it after so it will
        -- mark[SymbolInfo.OPTS].end_right_gvavity = true
        logger.debug("ext_mark CREATED: id=%d span=%s", mark_id, SymbolInfo.pos_to_string(mark))
    else
        logger.error("Error creating ext_mark: %s data=%s", SymbolInfo.pos_to_string(mark), vim.inspect(mark))
    end
    return ok, mark_id
end

---@param data SymbolData
---@return SymbolInfo | nil mark Found mark or nil if not found
---@return SymbolStatus status
function SymbolsWatcher:update_symbol(data)
    local symbol, line, line_index, status = self:get_symbol_info(data)
    if status == SymbolStatus.SizeChanged then
        ---@diagnostic disable: need-check-nil, param-type-mismatch
        local mark_core = symbol[SymbolInfo.CORE]

        local opts = symbol[SymbolInfo.OPTS]
        local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, self.buffer, self.namespace, mark_core.line, mark_core.col, opts)
        if ok then
            SymbolInfo.set_mark_id(symbol, mark_id)
            SymbolInfo.set_mark_updated(symbol, true)
            logger.debug("Symbol changed: %s", SymbolInfo.id_pos_to_string(symbol))
        end
        ---@diagnostic enable: need-check-nil, param-type-mismatch
    else if symbol and status == SymbolStatus.BadSize then
            logger.warn("Symbol deleted (bad size): %s data=%s", SymbolInfo.id_pos_to_string(symbol), vim.inspect(symbol))
            if line then
                self:remove_symbol_and_destroy(line, symbol, line_index)
            end
            return nil, status
        elseif symbol and status == SymbolStatus.None then
            -- Symbol exists and hasn't changed - mark as updated so it won't be garbage collected
            SymbolInfo.set_mark_updated(symbol, true)
            logger.debug("Symbol unchanged: %s", SymbolInfo.id_pos_to_string(symbol))
        end
    end
    return symbol, status
end

---@param data SymbolData
---@return SymbolInfo? mark
---@return LineInfo? line_info
---@return integer line_index
---@return SymbolStatus status
function SymbolsWatcher:get_symbol_info(data)
    --- about stale
    --- we do not create line and symbols when buffer changed before lsp returned us complete state
    --- otherwise we in danger creating empty marks
    --- in this situation we only update matched symbols

    local line, col, end_col = SymbolInfo.get_position_from_data(data)

    local line_info = self.lines[line]
    if line_info then
        -- Find existing symbol at this column
        for i, symbol in ipairs(line_info.symbols) do
            ---@type MarkCore
            local mark_core = symbol[SymbolInfo.CORE]
            -- Match symbols that need validation (validated_tick == 0 means needs validation)
            if mark_core.col == col
                -- and mark_core.validated_tick ~= self.changetick  
            then
                --actualyzing data and end column
                --setting end column is important because we watch symbol span and decide
                --if its deleted based on in, not waiting for lsp answer
                SymbolInfo.set_symbol_data(symbol, data, end_col, self.changetick)
                local status = end_col ~= mark_core.end_col and SymbolStatus.SizeChanged or SymbolStatus.None
                if SymbolInfo.is_bad_size(symbol) then
                    status = SymbolStatus.BadSize
                end

                return symbol, line_info, i, status
            end
        end
    end

    if false == self.is_lsp_actualizing and self.is_stale then
        return nil, nil, 0, SymbolStatus.None -- we will wait for next time
    end

    if col >= end_col then
        return nil, nil, 0, SymbolStatus.BadSize
    end

    -- line_info = self:create_line_state(line)
    -- self.lines[line] = line_info
    return self:add_new_mark_info(line, col, end_col, data), line_info, 0, SymbolStatus.New
end

---@param data SymbolData
---@return SymbolInfo mark Creates mark info and adds it to new marks table
function SymbolsWatcher:add_new_mark_info(line, col, end_col, data)
    local new_mark_info = SymbolInfo.new(line, col, end_col, data)
    -- Mark as validated since we just received fresh LSP data
    SymbolInfo.set_validated_tick(new_mark_info, self.changetick)
    self.new_symbols = self.new_symbols or {}
    logger.debug("Added new symbol: %s %s (validated_tick=%d)", SymbolInfo.id_pos_to_string(new_mark_info), data.sym.name, self.changetick)
    table.insert(self.new_symbols, new_mark_info)
    return new_mark_info
end

---@param line integer
---@return LineInfo line_state creates new line state
function SymbolsWatcher:create_line_info(line)
    local line_info = LineInfo.new(line)

    -- Debug logging
    logger.debug("Line created: %d, is_dry=%s", line, tostring(self:is_dry()))

    ---@type LineEventArgs
    local event_args = {
        line_info = line_info
    }
    self.OnLineCreated:trigger(event_args)
    return line_info
end

---@param line_info LineInfo
function SymbolsWatcher:destroy_line_with_symbols(line, line_info)
    -- table.move(line_state.symbols, start_index, #line_state.symbols, #existing_new_line.symbols + 1, existing_new_line.symbols)
    local symbols = line_info.symbols
    for i = 1, #symbols do
        self:destroy_symbol_mark(symbols[i])
    end
    self:destroy_line_state(line, line_info)
end

---@param line integer
---@param line_info LineInfo
function SymbolsWatcher:destroy_line_state(line, line_info)
    self.OnLineDestroyed:trigger({line = line, line_info = line_info})
end

---@param symbol SymbolInfo
---@param line_info LineInfo
function SymbolsWatcher:remove_symbol_and_destroy(line_info, symbol, i)
    table.remove(line_info.symbols, i)

    -- Update indices for remaining symbols (removal shifts following symbols)
    LineInfo.update_symbol_indices(line_info)

    self:destroy_symbol_mark(symbol)
    self.OnSymbolMarkDestroyed:trigger(symbol)
    LineInfo.needs_update(line_info)
end

---@param mark SymbolInfo
function SymbolsWatcher:destroy_symbol_mark(mark)
    local m_id = SymbolInfo.get_mark_id(mark)
    pcall(vim.api.nvim_buf_del_extmark, self.buffer, self.namespace, m_id)
    logger.debug("ext_mark DELETED: id=%d pos=%s", m_id, SymbolInfo.pos_to_string(mark))
end

---Merge symbols from one line to another when they've moved due to text edits
---@param start_index integer Index to start merging from
---@param line_info LineInfo Source line to merge symbols from
---@param existing_new_line LineInfo Target line to merge symbols into
function SymbolsWatcher:merge_lines(start_index, line_info, existing_new_line)
    local symbols = line_info.symbols
    for j = start_index, #symbols do
        -- Batch insertion: append unsorted, will sort once after loop
        LineInfo.add_symbol_unsorted(existing_new_line, symbols[j])
        self:on_change_symbol_line(line_info, existing_new_line, symbols[j])
    end

    -- Clear remaining symbols - they've all moved
    for j = #symbols, start_index, -1 do
        table.remove(symbols, j)
    end

    -- Sort once after batch
    table.sort(existing_new_line.symbols, function(a, b) return a[SymbolInfo.CORE].col < b[SymbolInfo.CORE].col end)

    -- Update indices after sorting (symbols may have moved positions)
    LineInfo.update_symbol_indices(existing_new_line)

    LineInfo.needs_update(line_info)
end

---Notify listeners when a symbol moves to a different line
---@param old_line LineInfo|nil Previous line (nil for new symbols)
---@param existing_new_line LineInfo New line the symbol moved to
---@param symbol SymbolInfo Symbol that changed lines
function SymbolsWatcher:on_change_symbol_line(old_line, existing_new_line, symbol)
    ---@type LineSymbolsChangedEventArgs
    local event_args = {
        line_info = existing_new_line,
        old_line = old_line,
        symbol = symbol,
    }
    self.OnSymbolLineChanged:trigger(event_args)
end


-- Shared parameter object for extmark queries (reused to reduce allocations)
---@type vim.api.keyset.get_extmark
local empty_param = { details = true }

---Update all symbol positions from their extmarks and detect stale symbols
---
--- This is a performance-critical hot path that runs on every buffer change.
--- It synchronizes our symbol cache with Neovim's extmark positions, which are
--- automatically updated by Neovim as the buffer is edited.
---
--- ALGORITHM OVERVIEW:
--- 1. Query each extmark for its current position (Neovim tracks this automatically)
--- 2. Detect size changes by comparing end_col (extmarks use end_right_gravity)
--- 3. Apply heuristics to determine if LSP revalidation is needed:
---    - Symbol shrank → ALWAYS stale (text was deleted)
---    - Symbol grew → MAYBE stale (could just be whitespace added)
--- 4. Use fast_change_validator to check if added text could be part of identifier
--- 5. Remove symbols whose extmarks were destroyed by Neovim (line deletions, etc.)
---
--- PERFORMANCE NOTES:
--- - Individual nvim_buf_get_extmark_by_id calls are ~40% faster than batch nvim_buf_get_extmarks
---   (Benchmarked: 0.057ms vs 0.086ms for typical buffers - see benchmark_approach() at EOF)
--- - This is because we skip position lookups and only query known mark IDs
--- - Extmarks automatically track position changes via Neovim's internal rope data structure
---
--- EXTMARK TRACKING:
--- - Symbols use `end_right_gravity = true` to automatically grow when text is inserted
--- - This allows instant detection of edits without waiting for LSP
--- - When end_col changes, we know the symbol was modified and may need revalidation
---
---@param symbol_flag boolean Whether to mark symbols as updated (true) or stale (false)
function SymbolsWatcher:actualize_symbol_marks_positions(symbol_flag)
    -- FUTURE OPTIMIZATION: Viewport filtering could skip off-screen symbols
    -- Commented out because current approach is already fast enough
    -- local viewport_range = nil
    -- if self.viewport and self.viewport.enabled then
    --     viewport_range = self.viewport:get_visible_range()
    -- end

    -- NOTE: Individual nvim_buf_get_extmark_by_id calls outperform batch nvim_buf_get_extmarks
    -- See benchmark results at end of file (lines 700-778)
    for line, line_info in pairs(self.lines) do
        -- -- VIEWPORT FILTER: Skip off-screen lines to reduce extmark queries
        -- if viewport_range and not self.viewport:is_line_in_range(line, viewport_range) then
        --     logger.debug("Symbol position update skipped (off-screen): line=%d", line)
        --     goto continue
        -- end

        line_info[LineInfo.CORE].update = false
        local i = 1
        local symbols = line_info.symbols
        while i <= #symbols do
            local symbol = symbols[i]

            -- ALTERNATIVE APPROACH (commented): Array unpacking
            -- Testing showed direct unpacking is slightly cleaner than table indexing
            -- local pos = vim.api.nvim_buf_get_extmark_by_id(self.buffer, self.namespace, SymbolInfo.get_mark_id(symbol), empty_param)
            -- if pos and #pos > 1 then
            --     local details = pos[3]
            --     print(vim.inspect(pos))
            --     SymbolInfo.set_updated(symbol, symbol_flag)
            --     SymbolInfo.set_position(symbol, pos[1], pos[2])
            --     i = i + 1
            -- else

            -- Query extmark position (Neovim automatically updates these as buffer changes)
            -- Returns: line, col, details table (with end_col, end_row, etc.)
            local ln, cl, details = unpack(vim.api.nvim_buf_get_extmark_by_id(self.buffer, self.namespace, SymbolInfo.get_mark_id(symbol), empty_param))

            if ln then
                -- Extmark still exists - update our cached position
                SymbolInfo.set_mark_updated(symbol, symbol_flag)
                -- Setting pos, col and end col from current extmark
                SymbolInfo.set_position(symbol, ln, cl, details.end_col)

                -- HEURISTIC: Detect if symbol size changed (indicates text edit within symbol)
                -- This leverages end_right_gravity to detect insertions without LSP
                if SymbolInfo.is_tick_size_changed(symbol) then
                    -- Symbol size changed - determine if we need expensive LSP revalidation

                    local symbol_prev_end_col = SymbolInfo.get_prev_end_col(symbol) -- Previous end (before edit)
                    local symbol_end_col = SymbolInfo.get_end_col(symbol)           -- Current end (after edit)

                    -- ASYMMETRIC HANDLING: Growth vs shrinkage have different implications
                    if symbol_end_col > symbol_prev_end_col then
                        -- Symbol GREW - text was inserted
                        -- OPTIMIZATION: Check if inserted text could be part of identifier
                        -- If it's just whitespace/punctuation, skip expensive LSP call

                        local text = self:get_line_text(symbol[SymbolInfo.CORE].line)
                        -- getting text added to symbol
                        local added_text = string.sub(text, symbol_prev_end_col + 1, symbol_end_col)

                        --fast_change_validator checks if added text is part of the symbol or not
                        if self.fast_change_validator(self, symbol, added_text) then
                            -- Added text contains potential identifier chars → needs LSP validation
                            -- Example: "func" → "funct" (could change symbol)
                            SymbolInfo.set_needs_validation(symbol)
                        else
                            -- Added text is only whitespace/punctuation → skip LSP call
                            -- Example: "func" → "func " (definitely doesn't change symbol)
                            -- FUTURE: Could restore prev_end_col to stop tracking this growth
                            -- Currently commented to preserve extmark state
                            SymbolInfo.set_end_col(symbol, symbol_end_col)
                        end
                    else
                        -- Symbol SHRANK - text was deleted
                        -- ALWAYS needs validation because identifier may have changed
                        -- Example: "function" → "func" (different symbol entirely)
                        SymbolInfo.set_needs_validation(symbol)
                        SymbolInfo.set_end_col(symbol, symbol_end_col)
                    end
                end
                i = i + 1
            else
                -- Extmark was destroyed by Neovim (line deleted, buffer cleared, etc.)
                -- Remove symbol from our cache - LSP will recreate it if it still exists
                logger.debug("ext_mark destroyed by nvim, deleting symbol: %s", SymbolInfo.pos_to_string(symbol))

                table.remove(symbols, i)
                -- Update indices for remaining symbols (removal shifts following symbols)
                LineInfo.update_symbol_indices(line_info)

                self.OnSymbolMarkDestroyed:trigger(symbol)
                LineInfo.needs_update(line_info)
                -- Don't increment i - we removed current element, next is now at position i
            end
        end

        ::continue::
    end
end

function SymbolsWatcher:set_all_staled()
    for _, line_info in pairs(self.lines) do
        line_info[LineInfo.CORE].update = false
        local i = 1
        local symbols = line_info.symbols
        while i <= #symbols do
            SymbolInfo.set_mark_updated(symbols[i], false)
            i = i + 1
        end
    end
end

function SymbolsWatcher:get_line_info_for_symbol(symbol)
    local line = SymbolInfo.get_line(symbol)
    return self.lines[line]
end


function SymbolsWatcher:get_line_text(line)
    return vim.api.nvim_buf_get_lines(self.buffer, line, line + 1, false)[1] or ""
end

--- Actualizes the line state after buffer changes or LSP updates.
--- This function handles symbol movements across lines, merging symbols that jumped
--- to the same line, and cleaning up empty lines.
---
--- Algorithm:
--- 1. First actualizes symbol mark positions via actualize_symbol_marks_positions()
--- 2. Iterates through all tracked lines and their symbols
--- 3. For each symbol, checks if it jumped to a different line:
---    - If all remaining symbols on the line jumped together: moves/merges entire line_info
---    - If only some symbols jumped: migrates individual symbols to target lines
--- 4. Triggers OnSymbolMarkChanged event for symbols that changed
--- 5. Cleans up empty lines (no symbols remaining)
--- 6. Replaces self.lines with the new line mapping
---
--- @param buffer_changed_run boolean true when buffer changed (quick update), false when doing full LSP actualization
function SymbolsWatcher:actualize_line_state(buffer_changed_run)
    --first we actualize symbols info only
    self:actualize_symbol_marks_positions(buffer_changed_run)

    local new_lines = {}
    --then we actualize lines
    for line, line_info in pairs(self.lines) do
        local i = 1

        local symbols = line_info.symbols
        while i <= #symbols do
            local symbol = symbols[i]
            local symbolCore = symbol[SymbolInfo.CORE]

            if symbolCore.line ~= line then
                -- Symbol jumped to another line
                -- Check if all remaining symbols jumped to the same line
                local all_jumped = true
                for j = i + 1, #symbols do
                    if SymbolInfo.get_line(symbols[j]) ~= symbolCore.line then
                        all_jumped = false
                        break
                    end
                end

                local existing_new_line = new_lines[symbolCore.line]

                if all_jumped then
                    -- All remaining symbols jumped to same line
                    if not existing_new_line and i == 1 then
                        -- Fast path: move entire line_state
                        new_lines[symbolCore.line] = line_info
                        LineInfo.set_line(line_info, symbolCore.line)
                        --we jumped no new line better update mark
                        --- we do not need to change it, unless from lsp data, line just jumped
                        -- LineInfo.needs_update(line_info)
                        logger.debug("Moved line: %d -> %d, is_dry=%s", line, symbolCore.line, tostring(self:is_dry()))
                        goto continue
                    end

                    -- Copy all remaining symbols to target line
                    if not existing_new_line then
                        existing_new_line = self:create_line_info(symbolCore.line)
                        new_lines[symbolCore.line] = existing_new_line
                    end

                     self:merge_lines(i, line_info, existing_new_line)
                    logger.debug("Merged lines: %d, is_dry=%s", line, tostring(self:is_dry()))
                    -- Exit the while loop since no more symbols to process
                    break
                else
                    -- Only this symbol jumped, others may stay or go elsewhere
                    if not existing_new_line then
                        existing_new_line = self:create_line_info(symbolCore.line)
                        new_lines[symbolCore.line] = existing_new_line
                    end

                    --removing from old line
                    table.remove(symbols, i)
                    -- Update indices for remaining symbols on old line
                    LineInfo.update_symbol_indices(line_info)
                    LineInfo.needs_update(line_info)

                    -- adding to existing_new_line (add_symbol will update indices)
                    LineInfo.add_symbol(existing_new_line, symbol)
                    self:on_change_symbol_line(line_info, existing_new_line, symbol)
                    -- Don't increment i for current line (removed element, next is now at i)
                end
            else
                if SymbolInfo.if_changed(symbol) then
                    self.OnSymbolMarkChanged:trigger(symbol)
                end
                i = i + 1
            end
        end

        -- Clean up empty lines
        if #symbols == 0 then
            self:destroy_line_state(line, line_info)
        else
            local existing_new_line = new_lines[line]
            if existing_new_line then
                self:merge_lines(1, line_info, existing_new_line)
                self:destroy_line_state(line, line_info)
                LineInfo.needs_update(existing_new_line)
            else
                -- Symbols were modified but line wasn't added yet (shouldn't happen, but safety check)
                new_lines[line] = line_info
            end
        end

        ::continue::
    end
    self.lines = new_lines
end

function SymbolsWatcher:actualize_buffer_change(changetick)
    self.changetick = changetick
    self.is_stale = true
    self.OnActualizeBufferChange:trigger({})

    --when we want to react fast on changes, doing some minimal job
    --atjusting current states of the marks without asking LSP
    --it is just looking at symbols marks and updates them with an old data
    -- if we have some changes when in process of receiving LSP data
    -- our current state is not perfect now, but still we like to actualize what we have at this moment 
    -- (deleting symbols if ext_mark is deleted and so lines, or moving marks and lines)
    -- so we just actualize current marks and symbols, we do not create anything even when we have data in new_marks (lsp actualize can run at this moment)
    self:actualize_line_state(true)
    self.OnActualizeEnd:trigger({})
    logger.debug("[Buffer changed run] ended")
end

function SymbolsWatcher:lsp_actualize(changetick)
    self.is_lsp_actualizing = true
    self.OnActualizeStart:trigger({})

    if self.changetick == changetick then
        --if we don't have any changes from the last tick, just mark data as stale
        --and wait for new lsp data
        self:set_all_staled()
        return
    end
    self.changetick = changetick
    self:actualize_line_state(false)
end

function SymbolsWatcher:lsp_actualize_append(changetick)
    --we do not append (because we do it only when viewport position changetick) when buffer is changed, because actualize_buffer_change will be called and then lsp_actualize
    if self.changetick ~= changetick then return end

    self.is_lsp_actualizing = true
    self.OnActualizeStart:trigger({})

    -- In append mode (scrolling), we're NOT re-validating existing symbols
    -- Mark all existing symbols as valid to prevent deletion in finish_lsp_actualization()
    for _, line_info in pairs(self.lines) do
        for _, symbol in ipairs(line_info.symbols) do
            SymbolInfo.set_mark_updated(symbol, true)
        end
    end
    logger.debug("Append mode: marked %d existing symbols as valid", vim.tbl_count(self.lines))
end

function SymbolsWatcher:cancel_lsp_actualization()
    self.is_lsp_actualizing = false
    self.OnActualizeCancelled:trigger({})
    --not sure if we shuold discard new symbols, but I suppose it is less messy that way
    --less messy is better, especially when we are editing code
    self.new_symbols = {}
end

function SymbolsWatcher:finish_lsp_actualization()
    local delete_counter = 0
    local created_counter = 0
    local changed_counter = 0

    local new_symbols = self.new_symbols
    -- we do not create marks during buffer_changed_run
    local new_marks_idx = 1

    -- Delete marks that no longer exist or changed
    for _, line_info in pairs(self.lines) do
        local i = 1
        local symbols = line_info.symbols
        while i <= #symbols do
            local symbol = symbols[i]
            if SymbolInfo.is_not_mark_updated(symbol) then
                -- Mark was removed - delete the old extmark
                delete_counter = delete_counter + 1
                -- TODO mb reuse mark in new_mark_infos has items
                self:remove_symbol_and_destroy(line_info, symbol, i)
            else
                i = i + 1
            end
        end
    end

    -- Add new marks if they exist
    if new_symbols then
        while new_marks_idx <= #new_symbols do
            local symbol = new_symbols[new_marks_idx]
            logger.debug("Adding new mark to buffer")

            local ok, mark_id = self:create_ext_mark_for_symbol(symbol)
            ---@type MarkCore
            local markCore = symbol[SymbolInfo.CORE]
            created_counter = created_counter + 1
            if ok then
                local line_info = self.lines[markCore.line]
                if not line_info then
                    logger.debug("Created line info for line %d", markCore.line)
                    line_info = self:create_line_info(markCore.line)
                    self.lines[markCore.line] = line_info
                end
                logger.debug("Adding symbol to line with mark_id: %d", mark_id)
                -- Single insertion: binary search + insert is faster than full sort
                LineInfo.add_symbol(line_info, symbol)
                self:on_change_symbol_line(nil,line_info, symbol)
            else
                --symbol was created by lsp, but something changed alrealy and this position doesn't exist
                --so we should tell adorners to delete it
                -- self:destroy_symbol_mark(symbol)
                self.OnSymbolMarkDestroyed:trigger(symbol)
                logger.warn("Symbol mark creation failed - position invalid")
            end
            new_marks_idx = new_marks_idx + 1
        end
    end

    for line, line_info in pairs(self.lines) do
        -- Clean up empty lines
        if #line_info.symbols == 0 then
            self:destroy_line_state(line, line_info)
            self.lines[line] = nil
        end
    end

    self.is_lsp_actualizing = false
    logger.debug_lazy(function()
        return string.format(
            "[SymbolInfos] new_marks=%d | lines=%d | created=%d | changed=%d | deleted=%d | is_dry=%s",
            new_symbols and #new_symbols or 0,
            vim.tbl_count(self.lines),
            created_counter,
            changed_counter,
            delete_counter,
            vim.inspect(self:is_dry())
        )
    end)
    self.OnActualizeEnd:trigger({})
    self.new_symbols = {}
    self.is_stale = false
end


local symbol_args = {}
---@param data SymbolData
function SymbolsWatcher:set_data_for_symbol(data)
    local symbol, status = self:update_symbol(data)
    if symbol then
        symbol_args.data = data
        symbol_args.symbol = symbol
        symbol_args.status = status
        --- it is better to not spawn a lot of throw away object as args, there may be a lot of symbols
        self.OnSymbolDataUpdated:trigger(symbol_args)
    end
end

function SymbolsWatcher:clear_buffer()
    vim.api.nvim_buf_clear_namespace(self.buffer, self.namespace, 0, -1)
end

function SymbolsWatcher:print_all_symbols()
    -- Find existing symbol at this column
    for line, line_state in pairs(self.lines) do
        print("line:" .. line)
        for _, symbol in ipairs(line_state.symbols) do
            print(string.format("symbol text: %s", vim.inspect(symbol[SymbolInfo.OPTS])))
        end
    end
end



---@param self SymbolsWatcher
local function benchmark(self)
    local iterations = 1
    local line_states_buffer = self.lines or {}

    print("=== Realistic Benchmark (simulating actual code flow) ===")

    -- ✅ APPROACH 1: Individual calls during iteration
    local empy_param ={details = true}
    local start1 = vim.uv.hrtime()
    for _ = 1, iterations do
        for _, lines_state in pairs(line_states_buffer) do
            for _, symbol in ipairs(lines_state.symbols) do
                local pos = vim.api.nvim_buf_get_extmark_by_id(self.buffer, self.namespace, symbol[SymbolInfo.CORE].mark_id, empy_param)
                -- print(vim.inspect(pos))
                if pos and #pos >= 2 then
                    SymbolInfo.set_position(symbol, pos[1], pos[2], pos[2]+1)
                    -- -- Simulate checking if moved
                    -- if pos[1] ~= symbol.line or pos[2] ~= symbol.col then
                    --     moved_count = moved_count + 1
                    --     symbol.line = pos[1]
                    --     symbol.col = pos[2]
                    -- end
                end
            end
        end
    end
    local time1 = (vim.uv.hrtime() - start1) / 1e6

    -- ✅ APPROACH 2: Batch call then lookup
    local start2 = vim.uv.hrtime()
    for _ = 1, iterations do
        local ext_marks = vim.api.nvim_buf_get_extmarks(self.buffer, self.namespace, 0, -1, empy_param)
        local positions = {}
        for _, mark in ipairs(ext_marks) do
            positions[mark[1]] = {line = mark[2], col = mark[3]}
        end

        for _, lines_state in pairs(line_states_buffer) do
            for _, symbol in ipairs(lines_state.symbols) do
                local symbol_core = symbol[SymbolInfo.CORE]
                local pos = positions[symbol_core.mark_id]
                if pos then
                    -- Simulate checking if moved
                    if pos.line ~= symbol_core.line or pos.col ~= symbol_core.col then
                        -- moved_count = moved_count + 1
                        SymbolInfo.set_position(symbol, pos.line, pos.col, pos.col+1)
                    end
                end
            end
        end
    end
    local time2 = (vim.uv.hrtime() - start2) / 1e6

    print(string.format("Individual calls: %.3fms", time1 / iterations))
    print(string.format("Batch call:       %.3fms", time2 / iterations))
    print(string.format("Difference:       %.3fms (%.0f%%)",
        math.abs(time1 - time2) / iterations,
        math.abs(time1 - time2) / math.min(time1, time2) * 100))
    -- it seems individual calls are faster!!!
    --
    -- 02:33:16 msg_show.lua_print === Realistic Benchmark (simulating actual code flow) ===
    --     02:33:16 msg_show.lua_print Individual calls: 0.057ms
    --     02:33:16 msg_show.lua_print Batch call:       0.086ms
    --     02:33:16 msg_show.lua_print Difference:       0.029ms (51%)
    -- 02:33:21 msg_show.lua_print === Realistic Benchmark (simulating actual code flow) ===
    --     02:33:21 msg_show.lua_print Individual calls: 0.056ms
    -- 02:33:21 msg_show.lua_print Batch call:       0.085ms
    -- 02:33:21 msg_show.lua_print Difference:       0.030ms (53%)
    -- 02:33:25 msg_show.lua_print === Realistic Benchmark (simulating actual code flow) ===
    --     02:33:25 msg_show.lua_print Individual calls: 0.067ms
    -- 02:33:25 msg_show.lua_print Batch call:       0.073ms
    -- 02:33:25 msg_show.lua_print Difference:       0.006ms (9%)
    -- 02:33:11 msg_showcmd 12
    -- 02:33:51 msg_show.lua_print === Realistic Benchmark (simulating actual code flow) ===
    --     02:33:51 msg_show.lua_print Individual calls: 0.053ms
    -- 02:33:51 msg_show.lua_print Batch call:       0.100ms
    -- 02:33:51 msg_show.lua_print Difference:       0.047ms (87%)
end
-- Run with: :lua require('your_module').benchmark_approach()
SymbolsWatcher.benchmark_approach = benchmark

return SymbolsWatcher
