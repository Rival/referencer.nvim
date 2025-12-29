-- ============================================================================
-- Imports
-- ============================================================================

local SymbolAdorner = require("referencer.adorners.symbol-adorner")
local SymbolsWatcher = require("referencer.symbols-watcher.symbols-watcher")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local LineInfo = require("referencer.symbols-watcher.line-info")
local AnimationManager = require("referencer.animation-manager")
local logger = require("referencer.logger").for_module("virtual_lines_adorner")
local formatters = require("referencer.adorners.virtual-lines-formatters")

-- ============================================================================
-- Type Definitions
-- ============================================================================

---@class VirtualLineAdornerOptions : SymbolAdornerOpions
---@field above boolean Position virtual lines above (true) or below (false) code
---@field formatter? string|VirtualLineFormatter|GetVirtualTextBySymbol|VirtualLineFormatterConfig Formatter: string (simple) or config table (advanced)
---@field align_first? any DEPRECATED: use formatter = {type="first_and_following", first=...}
---@field align_following? any DEPRECATED: use formatter = {type="first_and_following", following=...}

---@class VirtualLineFormatterConfig
---@field type "single"|"first_and_following"|"position"|"selector" Formatter strategy type
---@field formatter? string|VirtualLineFormatter|GetVirtualTextBySymbol For type="single": the formatter to use
---@field first? string|VirtualLineFormatter|GetVirtualTextBySymbol For type="first_and_following": first symbol formatter
---@field following? string|VirtualLineFormatter|GetVirtualTextBySymbol For type="first_and_following": 2nd+ symbols formatter
---@field default? string|VirtualLineFormatter|GetVirtualTextBySymbol For type="position": fallback formatter
---@field [integer]? string|VirtualLineFormatter|GetVirtualTextBySymbol For type="position": position-specific formatters (1-based)
---@field selector? FormatterSelectorFunc For type="selector": custom selection function

---@alias FormatterSelectorFunc fun(symbol: SymbolInfo, index: integer, line_info: LineInfo): string|VirtualLineFormatter|GetVirtualTextBySymbol

---@class VirtualLinesAdorner : SymbolAdorner
---@field formatter VirtualLineFormatter Formatter for rendering virtual text (can be SingleFormatter, FirstAndOthersFormatter, PositionFormatter, or SelectorFormatter)
local VirtualLinesAdorner = setmetatable({}, {__index = SymbolAdorner})
VirtualLinesAdorner.__index = VirtualLinesAdorner

---@class VirtualLineData
---@field mark_id integer|nil Extmark ID for the virtual line (nil if not yet created)
---@field new_line integer|nil New line after taking data from buffer, -1 if not changed (currently unused)
---@field text string Cached line text from buffer
---@field needs_update boolean Flag indicating line needs re-rendering
---@field animation_time number|nil Accumulated animation time in ms (added dynamically during animations)
---@field animation_last_update number|nil Last animation update timestamp from vim.loop.now() (added dynamically)
---@field animation_cleanup function|nil Cleanup function to unregister animation callback
---@field virt_text_chunks table|nil Cached array of virtual text chunks (reused across renders)

---@class VirtualLinesSymbolAdornerData
---@field symbol_start_col integer Buffer column where symbol starts
---@field visual_end_col integer Visual column where symbol ends
---@field text_current_col integer Current column position in virtual line
---@field text_line_spacing table|nil Spacing chunk: {spaces_string, "Normal"} or nil
---@field text_line table Virtual text chunk: {text, highlight_group}
---@field text_target_col integer Target column where this symbol's text should appear
---@field format_func function Cached formatter function (from FormatterBase:set_symbol_state)
---@field is_animated boolean Whether the cached formatter expects animation time parameter
---@field text_chunks table|nil Cached chunks array: {{text, hl}, ...}
---@field width_cache integer|nil Cached total display width for change detection

-- Type aliases for formatter functions
---@alias GetVirtualTextBySymbol fun(adorner:VirtualLinesAdorner, line:integer, span_col:integer, span_end_col:integer, symbol_col:integer, symbol_end_col:integer, symbol_info: SymbolInfo, adorner_symbol_data: VirtualLinesSymbolAdornerData):table|nil, integer, integer
---@alias GetVirtualTextBySymbolAnimated fun(adorner:VirtualLinesAdorner, line:integer, span_col:integer, span_end_col:integer, symbol_col:integer, symbol_end_col:integer, symbol_info:SymbolInfo, adorner_symbol_data:VirtualLinesSymbolAdornerData, time:number):table|nil, integer, integer
-- Returns: ({{text, hl}, {text2, hl2}, ...}, target_col, total_width) or (nil, col, 0) to skip symbol
---@alias ShouldAnimateVirtualLineFunc fun(symbol:SymbolInfo, adorner_data:VirtualLinesSymbolAdornerData):boolean

-- ============================================================================
-- Formatter Presets
-- ============================================================================

-- Formatter presets with animation support (populated from presets file at end of module)
VirtualLinesAdorner.formatters = {}

-- Note: Alignment formatters (most_left, left, center, right) are defined in virtual-lines-adorner-presets.lua

-- ============================================================================
-- Helper Functions
-- ============================================================================

--- Update virtual line display for a specific line
---@param adorner VirtualLinesAdorner
---@param line_info LineInfo
---@param line_data VirtualLineData
---@param line integer
local function update_virtual_line_for_line(adorner, line_info, line_data, line)
    if  line_data.needs_update then
        line_data.text = adorner.watcher:get_line_text(line)
    end
    -- Get line text for calculating positions
    local indent = line_data.text:match("^%s*") or ""
    local line_start_col = vim.fn.strdisplaywidth(indent)

    -- Reuse virt_text_chunks array to avoid allocations
    if not line_data.virt_text_chunks then
        line_data.virt_text_chunks = {}
    end
    local virt_text_chunks = line_data.virt_text_chunks
    local chunk_idx = 1  -- Track position for index assignment
    local text_last_col = 0  -- Track our position in building the virtual line

    -- Build virtual line with text at specific columns

    local line_changed = false
    for i, symbol in ipairs(line_info.symbols) do
        --line_info may contain symbols for other adorners
        if not adorner:is_symbol_supported(symbol) then goto continue end

        local symbol_col = SymbolInfo.get_col(symbol)
        local symbol_end_col = SymbolInfo.get_end_col(symbol)
        local adorner_data = SymbolInfo.get_adorner_data(symbol, adorner)
        ---@cast adorner_data VirtualLinesSymbolAdornerData

        -- Verify index is up-to-date and re-cache formatter if it changed
        local current_index = SymbolInfo.get_index(symbol)
        if current_index ~= i then
            -- Index changed (symbol moved positions on line) - update it and re-cache formatter
            SymbolInfo.set_index(symbol, i)
            adorner.formatter:set_symbol_index(adorner_data, symbol, i)
        end

        adorner_data.symbol_start_col = symbol_col
        adorner_data.visual_end_col = symbol_end_col

        -- Calculate available space for this symbol
        local span_start_col-- it is start col of available space
        if i == 1 then
            span_start_col = line_start_col  -- First symbol: start at first non-whitespace
        else
            span_start_col = text_last_col
        end

        local span_end_col-- it is end col of available space
        if i < #line_info.symbols then
            -- Use next symbol's column position (may overlap during edits before LSP updates)
            local next_symbol_col = line_info.symbols[i + 1][SymbolInfo.CORE].col - 1
            -- Ensure span doesn't end before current symbol (prevents invalid geometry during dry runs)
            span_end_col = math.max(next_symbol_col, symbol_end_col + 1)
        else
            -- Last symbol: give it space until reasonable line width
            span_end_col = math.max(symbol_end_col + 20, 120)
        end

        -- Format text using cached formatter function (cached by OnSymbolDataUpdated event)
        local chunks, target_col, total_width = adorner.formatter:format_symbol(adorner, line, span_start_col, span_end_col,
                                                                                 symbol_col, symbol_end_col, symbol,
                                                                                 adorner_data, line_data)

        if not chunks then goto continue end  -- Formatter returned nil

        -- Fast path: Check if formatter returned cached chunks (reference equality)
        -- Formatters can signal "reuse" by returning adorner_data.text_chunks directly
        local reuse_cached = (chunks == adorner_data.text_chunks)

        if not reuse_cached then
            line_changed = true

            -- Update caches
            adorner_data.text_chunks = chunks
            adorner_data.width_cache = total_width
            adorner_data.text_current_col = text_last_col
            adorner_data.text_target_col = target_col

            -- Update spacing table IN-PLACE
            local spacing = math.max(0, target_col - text_last_col)
            if spacing > 0 then
                text_last_col = text_last_col + spacing
                if not adorner_data.text_line_spacing then
                    adorner_data.text_line_spacing = { string.rep(" ", spacing), "Normal" }
                else
                    ---@diagnostic disable-next-line: assign-type-mismatch
                    adorner_data.text_line_spacing[1] = string.rep(" ", spacing)
                end
            else
                adorner_data.text_line_spacing = nil
            end
        end

        -- Build virt_text_chunks (use index assignment for reuse)
        if adorner_data.text_line_spacing then
            virt_text_chunks[chunk_idx] = adorner_data.text_line_spacing
            chunk_idx = chunk_idx + 1
        end
        -- Add all cached chunks
        for _, chunk in ipairs(adorner_data.text_chunks) do
            virt_text_chunks[chunk_idx] = chunk
            chunk_idx = chunk_idx + 1
        end
        text_last_col = text_last_col + adorner_data.width_cache

        ::continue::
    end

    -- Clear excess elements from previous renders
    for i = chunk_idx, #virt_text_chunks do
        virt_text_chunks[i] = nil
    end

    if text_last_col == 0 then
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

-- ============================================================================
-- VirtualLinesAdorner Main Class
-- ============================================================================

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

    -- Create formatter using factory from virtual-lines-formatters module
    self.formatter = formatters.create_formatter(opts, VirtualLinesAdorner.formatters)

    self:Enable()
end

--- Manage per-line animation callback registration
--- Registers callback when any symbol on line is animated, removes when none are
---@param line_info LineInfo
---@param line_data VirtualLineData
---@param line integer Line number
local function manage_line_animation(self, line_info, line_data, line)
    -- ========================================================================
    -- PHASE 1: Detection - Check if this line needs animation
    -- ========================================================================

    -- Scan all symbols on this line to determine if any require animation
    local should_animate_line = false
    local interval = 150  -- Default animation update interval (ms)

    for _, symbol in ipairs(line_info.symbols) do
        -- Skip symbols not handled by this adorner (e.g., wrong kind/type)
        if not self:is_symbol_supported(symbol) then goto continue_symbol end

        local adorner_symbol_data = SymbolInfo.get_adorner_data(symbol, self)
        ---@cast adorner_symbol_data VirtualLinesSymbolAdornerData

        -- Check if this symbol's formatter is animated
        if adorner_symbol_data.is_animated then
            should_animate_line = true

            -- Extract animation interval from the formatter configuration
            -- (only the first animated symbol's interval is used for the line)
            local symbol_index = SymbolInfo.get_index(symbol)
            local delegate = self.formatter:get_delegate(symbol_index)
            interval = delegate.animation_interval or 150
            break  -- Found one - that's enough to animate the entire line
        end

        ::continue_symbol::
    end

    -- ========================================================================
    -- PHASE 2: State Transition - Register or unregister callback as needed
    -- ========================================================================

    -- Check current callback state (cleanup function exists = callback registered)
    local has_callback = line_data.animation_cleanup ~= nil

    -- STATE: Need animation but no callback → START animation
    if should_animate_line and not has_callback then
        -- Register a callback that fires on each animation frame
        line_data.animation_cleanup = AnimationManager.add_animated_callback(function(now)
            local last_update = line_data.animation_last_update or 0

            -- Throttle updates to match the configured interval (e.g., 150ms)
            if now - last_update >= interval then
                -- Advance animation time (used by formatters for effects)
                line_data.animation_time = (line_data.animation_time or 0) + interval
                line_data.animation_last_update = now
                line_data.needs_update = true

                -- Trigger re-render with updated animation time
                update_virtual_line_for_line(self, line_info, line_data, line)
            end
        end)

    -- STATE: Don't need animation but have callback → STOP animation
    elseif not should_animate_line and has_callback then
        -- Unregister the animation callback (line_data.animation_cleanup is the cleanup function)
        line_data.animation_cleanup()

        -- Clear all animation state fields
        line_data.animation_cleanup = nil
        line_data.animation_time = nil
        line_data.animation_last_update = nil
        line_data.needs_update = true

        -- Final render to show static (non-animated) state
        update_virtual_line_for_line(self, line_info, line_data, line)
    end

    -- STATE: Need animation and have callback → no action (already animating)
    -- STATE: Don't need animation and no callback → no action (already static)
end

function VirtualLinesAdorner:Enable()
    self:AddUnsubHook(self.watcher.OnSymbolMarkChanged:subscribe(function (symbol)

        if (self.watcher:is_dry() or self.watcher.is_stale) and
            self:is_symbol_supported(symbol)
        then
            local line_info = self.watcher:get_line_info_for_symbol(symbol)
            local line_data = LineInfo.get_or_create_adorner_data(line_info, self)
            ---@cast line_data VirtualLineData
            line_data.needs_update = true

            -- Update formatter state when symbol mark changes (validated_tick may have changed)
            local adorner_data = SymbolInfo.get_adorner_data(symbol, self)
            self.formatter:set_symbol_state(adorner_data, symbol)

            -- Manage animation callback registration based on symbol animation states
            local line = line_info[LineInfo.CORE].line
            manage_line_animation(self, line_info, line_data, line)

            logger.debug("Virtual line needs update: line=%d symbol mark changed", line_info[LineInfo.CORE].line)
        end
    end))

    ---@param args SymbolDataChangedEventArgs
    self:AddUnsubHook(self.watcher.OnSymbolDataUpdated:subscribe(function (args)
        if self:is_symbol_supported(args.symbol) then
            -- Always update cached formatter state (even for new symbols)
            local adorner_data = SymbolInfo.get_adorner_data(args.symbol, self)
            self.formatter:set_symbol_state(adorner_data, args.symbol)

            -- Only update line data if symbol has been assigned a line (not New status)
            -- NOTE: new symbols don't have line, they will get it later via OnSymbolLineChanged
            if args.status ~= SymbolsWatcher.SymbolStatus.New then
                local line_info = self.watcher:get_line_info_for_symbol(args.symbol)
                local line_data = LineInfo.get_or_create_adorner_data(line_info, self)
                ---@cast line_data VirtualLineData
                line_data.needs_update = true

                -- Manage animation callback registration based on symbol animation states
                local line = line_info[LineInfo.CORE].line
                manage_line_animation(self, line_info, line_data, line)

                logger.debug("Virtual line needs update: line=%d symbol data updated", line_info[LineInfo.CORE].line)
            end
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
            ---@cast line_data VirtualLineData
            line_data.needs_update = true

            -- Manage animation for new line
            local line = args.line_info[LineInfo.CORE].line
            manage_line_animation(self, args.line_info, line_data, line)

            if args.old_line then
                local old_line_data = LineInfo.get_or_create_adorner_data(args.old_line, self)
                ---@cast old_line_data VirtualLineData
                old_line_data.needs_update = true

                -- Manage animation for old line (may need to stop if no more animated symbols)
                local old_line_num = args.old_line[LineInfo.CORE].line
                manage_line_animation(self, args.old_line, old_line_data, old_line_num)
            end
            logger.debug("Virtual line needs update: line=%d symbol line changed", args.line_info[LineInfo.CORE].line)
        end
    end))

    ---@param symbol SymbolInfo
    self:AddUnsubHook(self.watcher.OnSymbolMarkDestroyed:subscribe(function (symbol)
        if  self:is_symbol_supported(symbol) then
            local line_info = self.watcher:get_line_info_for_symbol(symbol)
            local line_data = LineInfo.get_or_create_adorner_data(line_info, self)
            ---@cast line_data VirtualLineData
            line_data.needs_update = true

            -- Manage animation (may need to stop if this was the last animated symbol)
            local line = line_info[LineInfo.CORE].line
            manage_line_animation(self, line_info, line_data, line)

            logger.debug("Virtual line needs update: line=%d symbol destroyed", line_info[LineInfo.CORE].line)
        end
    end))


    self:AddUnsubHook(self.watcher.OnLineDestroyed:subscribe(function (args)
        local adorner_data = LineInfo.get_adorner_data(args.line_info, self)
        ---@cast adorner_data VirtualLineData|nil
        if adorner_data and adorner_data.mark_id and adorner_data.mark_id > 0 then
            logger.debug("Virtual line destroyed: line=%d mark=%d is_dry=%s", args.line, adorner_data.mark_id, tostring(self.watcher:is_dry()))
            pcall(vim.api.nvim_buf_del_extmark, self.watcher.buffer, self.watcher.namespace, adorner_data.mark_id)
        end
    end))

    self:AddUnsubHook(self.watcher.OnActualizeEnd:subscribe(function (_args)
        for line, line_state in pairs(self.watcher.lines) do
            local adorner_data = LineInfo.get_adorner_data(line_state, self)
            if adorner_data and adorner_data.needs_update then
                ---@cast adorner_data VirtualLineData
                -- Always update virtual lines (remove 'changed' check since it's not set anywhere)
                update_virtual_line_for_line(self, line_state, adorner_data, line)
            end
        end
    end))

    -- Note: Animation is now managed per-line via manage_line_animation()
    -- Callbacks are registered dynamically when lines have animated symbols
end

-- ============================================================================
-- Module Exports
-- ============================================================================

-- Load formatter presets
local create_formatters = require("referencer.adorners.virtual-lines-adorner-presets")
VirtualLinesAdorner.formatters = create_formatters(formatters.VirtualLineFormatter)

-- Export the formatter class for user customization
VirtualLinesAdorner.Formatter = formatters.VirtualLineFormatter

return VirtualLinesAdorner
