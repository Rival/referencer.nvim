local config = require("referencer.config")
local utils = require("referencer.utils")
local SymbolAdorner = require("referencer.adorners.symbol-adorner")
local SymbolsWatcher = require("referencer.symbols-watcher.symbols-watcher")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local LineInfo = require("referencer.symbols-watcher.line-info")
local logger = require("referencer.logger").for_module("virtual_lines_adorner")


---@class VirtualLineAdornerOptions : SymbolAdornerOpions
---@field align_first any
---@field align_following any
---@field above boolean

---@class VirtualLinesAdorner : SymbolAdorner
---@field first_symbol_formatter any
---@field following_symbol_formatter any
local VirtualLinesAdorner = setmetatable({}, {__index = SymbolAdorner})
VirtualLinesAdorner.__index = VirtualLinesAdorner

---@class VirtualLineData
---@field mark_id integer mark_id for virtual line
---@field new_line integer new_line new line after taking data from buffer, -1 if not changed
---@field text string cached text
---@field needs_update boolean cached text


-- Built-in alignment functions for virtual lines
VirtualLinesAdorner.aligners = {}


---@alias GetVirtualTextBySymbol fun(adorner:InlineAdorner, line:integer, span_col:integer,span_end_col:integer, symbol_col:integer,symbol_end_col:integer, symbol_info: SymbolInfo, adorner_symbol_data: any):any[]|nil, integer


---@type GetVirtualTextBySymbol
function VirtualLinesAdorner.aligners.most_left(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    if SymbolInfo.is_stale(symbol_info) then
        return "?", span_col
    end
    local text = string.format(config.options.format or "→ %d", refs_count)
    -- span_col is already set correctly by the caller:
    -- - for first symbol: line's first non-whitespace column
    -- - for following symbols: span_end_col of previous symbol + 1
    return text, span_col
end

---@type GetVirtualTextBySymbol
function VirtualLinesAdorner.aligners.left(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    return text, symbol_col
end

---@type GetVirtualTextBySymbol
function VirtualLinesAdorner.aligners.center(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    local symbol_width = symbol_end_col - symbol_col
    local text_width = #text
    local center_offset = math.floor((symbol_width - text_width) / 2)
    local col = math.max(span_col, symbol_col + center_offset)
    return text, col
end

---@type GetVirtualTextBySymbol
function VirtualLinesAdorner.aligners.right(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    local text_width = #text
    local col = math.max(span_col, symbol_end_col - text_width)
    return text, col
end

---@param adorner VirtualLinesAdorner
---@param line_data VirtualLineData
local function update_virtual_line_for_line(adorner, line_info, line_data, line)
    -- Sort symbols by column
    table.sort(line_info.symbols, function(a, b) return a[SymbolInfo.CORE].col < b[SymbolInfo.CORE].col end)

    if  line_data.needs_update then
        line_data.text = adorner.watcher:get_line_text(line)
    end
    -- Get line text for calculating positions
    local indent = line_data.text:match("^%s*") or ""
    local line_start_col = #indent

    -- Helper function to find first non-whitespace after a position
    local function find_next_nonwhitespace(text, start_pos)
        -- start_pos points to the first char after symbol name (e.g., the semicolon)
        -- We want to find non-whitespace AFTER that position
        -- Buffer is 0-indexed, Lua strings are 1-indexed
        -- So buffer position N = Lua string index N+1
        -- To start AFTER position start_pos, we need start_pos + 1 (buffer) = start_pos + 2 (Lua)
        local substr = text:sub(start_pos + 2)
        local ws_match = substr:match("^%s*")
        local offset = ws_match and #ws_match or 0
        -- We're looking at start_pos+1 in the buffer, then skipping whitespace
        return start_pos + 1 + offset
    end


    local last_symbol_end_col = 0  -- Track where the last symbol ended in the buffer
    local virt_text_chunks = {}
    local current_col = 0  -- Track our position in building the virtual line

    -- Build virtual line with text at specific columns

    local line_changed = false
    for i, symbol in ipairs(line_info.symbols) do

        -- Calculate symbol end column
        -- Note: LSP might give us qualified names like "M.aligners.func" 
        -- but only "func" appears in the buffer at the position
        -- So we need to extract the actual text from the buffer
        -- local symbol_col = symbol_info.col

        -- Extract actual text at the position to get real length
        -- Look for word boundaries (space, punctuation, etc.)
        local symbol_data = SymbolInfo.get_symbol_data(symbol)



        local col = symbol[SymbolInfo.CORE].col
        local adorner_data = SymbolInfo.get_adorner_data(symbol, adorner)

        local symbol_name = symbol_data.sym.name or ""
        local after_col_text = line_data.text:sub(col + 1)  -- +1 for Lua indexing
        local actual_symbol = after_col_text:match("^([%w_]+)")
        local actual_length = actual_symbol and #actual_symbol or #symbol_name
        local visual_end_col = col + actual_length
        local symbol_start_col = col
        local symbol_end_col = visual_end_col
        adorner_data.visual_end_col = visual_end_col
        adorner_data.symbol_start_col = symbol_start_col

        if not adorner:is_type_supported(symbol_data.kind) then
            -- Update where this symbol ended in the buffer for next cycle
            last_symbol_end_col = symbol_end_col
            goto continue
        end

        -- Calculate available space for this symbol
        local span_start_col
        if i == 1 then
            span_start_col = line_start_col  -- First symbol: start at first non-whitespace
        else
            -- Following symbols: find first non-whitespace after previous symbol ended
            local calculated_start = find_next_nonwhitespace(line_data.text, last_symbol_end_col)
            -- However, if the actual symbol starts BEFORE our calculated position
            -- (can happen when LSP gives qualified names like "M.aligners.func" but only "func" is in buffer),
            -- use the actual symbol position instead
            span_start_col = math.min(calculated_start, symbol_start_col)
        end

        local span_end_col
        if i < #line_info.symbols then
            span_end_col = SymbolInfo.get_adorner_data(line_info.symbols[i + 1], adorner).visual_start_col
        else
            -- Last symbol: give it space until reasonable line width
            span_end_col = math.max(symbol_end_col + 20, 120)
        end

        -- Call appropriate drawer
        local drawer = i == 1 and adorner.first_symbol_formatter or adorner.following_symbol_formatter
        local text, target_col = drawer(adorner, line, span_start_col, span_end_col, symbol_start_col, symbol_end_col, symbol)

        if
true
            -- adorner_data.text ~= text or
            -- target_col ~= adorner_data.text_target_col or
            -- adorner_data.text_current_col ~= current_col 

        then
            -- print(string.format("changed %s(si:%s) current_col: %s(si:%s) target_col: %d(si:%s)",
            --     text, tostring(symbol_info.text),
            --     current_col, tostring(symbol_info.text_current_col),
            --     target_col, tostring(symbol_info.text_target_col)
            -- ))
            -- text was updated
            line_changed = true

            adorner_data.text = text
            adorner_data.text_current_col = current_col

            -- Add spacing from current position to symbol position
            local spacing = math.max(0, target_col - current_col)
            if spacing > 0 then
                current_col = current_col + spacing
                adorner_data.text_line_spacing = { string.rep(" ", spacing), "Normal" }
            else
                adorner_data.text_line_spacing = nil
            end
            adorner_data.text_line = { text, adorner.hl_group }
            -- print(vim.inspect(adorner_data.text_line))
            adorner_data.text_target_col = target_col
        else

        end
        local spacing = math.max(0, target_col - current_col)
        if adorner_data.text_line_spacing then
            table.insert(virt_text_chunks, adorner_data.text_line_spacing)
            current_col = current_col + spacing
        end
        -- Add the symbol text
        table.insert(virt_text_chunks, adorner_data.text_line)
        current_col = current_col + #text

        -- Update where this symbol ended in the buffer for next cycle
        last_symbol_end_col = symbol_end_col
        ::continue::
    end

    if current_col == 0 then
        --all symbols become not drawable (maybe they changed their type), we better delete mark
        if line_data.mark_id and line_data.mark_id > 0 then
            logger.debug("Virtual line destroyed - no symbols to draw: line=%d mark=%d", line, line_data.mark_id)
            pcall(vim.api.nvim_buf_del_extmark, adorner.watcher.buffer, adorner.watcher.namespace, line_data.mark_id)
        end
        return
    end

    if line_changed or line_data.needs_update then
        line_data.needs_update = false
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, adorner.watcher.buffer, adorner.watcher.namespace, line, 0, {
            id = line_data.mark_id,
            virt_lines = { virt_text_chunks },
            virt_lines_above = adorner.above,
            hl_mode = "combine",
            virt_lines_overflow = "scroll"
        })

        if ok then
            if not line_data.mark_id then
                logger.debug("Virtual line mark created: line=%d mark_id=%d", line, id)
            else
                logger.debug("Virtual line changed: line=%d", line)
            end
            line_data.mark_id = id
        end
    end
end

---@param  watcher SymbolsWatcher
function VirtualLinesAdorner:new(watcher)
    -- Создаем через родительский конструктор
    local instance = SymbolAdorner.new(self, watcher)
    return instance
end

---@param  opts VirtualLineAdornerOptions
function VirtualLinesAdorner:init(opts, index, kinds_mask)
    SymbolAdorner.init(self, opts, index, kinds_mask)
    self.hl_group = require("referencer.config").get_hl_group()
    self.above = opts.above


    self.first_symbol_formatter = utils.resolve_callback_from_options(opts.align_first, VirtualLinesAdorner.aligners,"most_left")
    self.following_symbol_formatter = utils.resolve_callback_from_options(opts.align_following, VirtualLinesAdorner.aligners,"most_left")


    self:Enable()
end


function VirtualLinesAdorner:Enable()
    -- self:AddUnsubHook(self.watcher.OnLineCreated:subscribe(function (args)
    --     ---@cast args LineEventArgs
    --     local adorner_data = LineInfo.get_adorner_data(args.line_info, self)
    --     -- adorner_data.mark_id = -1
    --     -- LineInfo.needs_update(args.line_info)
    -- end))

    self:AddUnsubHook(self.watcher.OnSymbolMarkChanged:subscribe(function (symbol)

        if (self.watcher:is_dry() or self.watcher.is_stale) and
            self:is_symbol_supported(symbol)
        then
            local line_info = self.watcher:get_line_info_for_symbol(symbol)
            local line_data = LineInfo.get_or_create_adorner_data(line_info, self)
            line_data.needs_update = true
            logger.debug("Virtual line needs update: line=%d symbol mark changed", line_info[LineInfo.CORE].line)
        end
    end))
    
    ---@param args SymbolDataChangedEventArgs
    self:AddUnsubHook(self.watcher.OnSymbolDataUpdated:subscribe(function (args)
        -- NOTE: new symbols don't have line, we they will get it later
        if args.status ~= SymbolsWatcher.SymbolStatus.New and self:is_symbol_supported(args.symbol) then
            local line_info = self.watcher:get_line_info_for_symbol(args.symbol)
            local line_data = LineInfo.get_or_create_adorner_data(line_info, self)
            line_data.needs_update = true
            logger.debug("Virtual line needs update: line=%d symbol data updated", line_info[LineInfo.CORE].line)
        end
    end))
    
    ---@param args LineSymbolsChangedEventArgs
    self:AddUnsubHook(self.watcher.OnSymbolLineChanged:subscribe(function (args)
        if
            -- (self.watcher:is_dry() or self.watcher.is_stale)
            -- and
            self:is_symbol_supported(args.symbol)
        then
            local line_data = LineInfo.get_or_create_adorner_data(args.line_info, self)
            line_data.needs_update = true
            if args.old_line then
                local old_line_data = LineInfo.get_or_create_adorner_data(args.old_line, self)
                old_line_data.needs_update = true
            end
            logger.debug("Virtual line needs update: line=%d symbol line changed", args.line_info[LineInfo.CORE].line)
        end
    end))
    
    ---@param symbol SymbolInfo
    self:AddUnsubHook(self.watcher.OnSymbolMarkDestroyed:subscribe(function (symbol)
        if  self:is_symbol_supported(symbol) then
            local line_info = self.watcher:get_line_info_for_symbol(symbol)
            local line_data = LineInfo.get_or_create_adorner_data(line_info, self)
            line_data.needs_update = true
            logger.debug("Virtual line needs update: line=%d symbol destroyed", line_info[LineInfo.CORE].line)
        end
    end))
    

    self:AddUnsubHook(self.watcher.OnLineDestroyed:subscribe(function (args)
        local adorner_data = LineInfo.get_adorner_data(args.line_info, self)
        if adorner_data and adorner_data.mark_id and adorner_data.mark_id > 0 then
            logger.debug("Virtual line destroyed: line=%d mark=%d is_dry=%s", args.line, adorner_data.mark_id, tostring(self.watcher:is_dry()))
            pcall(vim.api.nvim_buf_del_extmark, self.watcher.buffer, self.watcher.namespace, adorner_data.mark_id)
        end
    end))

    self:AddUnsubHook(self.watcher.OnActualizeEnd:subscribe(function (args)
        for line, line_state in pairs(self.watcher.lines) do
            local adorner_data = LineInfo.get_adorner_data(line_state, self)
            if adorner_data and adorner_data.needs_update then
                ---@cast adorner_data VirtualLineData
                -- Always update virtual lines (remove 'changed' check since it's not set anywhere)
                update_virtual_line_for_line(self, line_state, adorner_data, line)
            end
        end
    end))
end

return VirtualLinesAdorner
