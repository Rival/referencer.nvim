-- ============================================================================
-- Imports
-- ============================================================================

local config = require("referencer.config")
local utils = require("referencer.utils")
local SymbolAdorner = require("referencer.adorners.symbol-adorner")
local SymbolsWatcher = require("referencer.symbols-watcher.symbols-watcher")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local FormatterBase = require("referencer.adorners.formatter-base")
local AnimationManager = require("referencer.animation-manager")
local logger = require("referencer.logger").for_module("inline_adorner")

-- ============================================================================
-- Type Definitions
-- ============================================================================

-- Type aliases for formatter functions
---@alias GetVirtText fun(watcher:InlineAdorner, line:integer, col: integer, symbol_info: SymbolInfo, adorner_data: any):any[]|nil, integer
---@alias GetVirtTextAnimated fun(adorner:InlineAdorner, line:integer, col:integer, symbol_info:SymbolInfo, adorner_data:any, time:number):any[]|nil, integer
---@alias ShouldAnimateFunc fun(symbol:SymbolInfo, adorner_data:any):boolean
---@alias SetVirtualTextFunc fun(adorner:InlineAdorner, watcher:SymbolsWatcher, line:integer, col: integer, symbol_data: SymbolData)

---@class InlineAdornerFormatter : FormatterBase
---@field text GetVirtText Normal state formatter
---@field text_animated GetVirtTextAnimated|nil Animated normal state (optional, falls back to text)
---@field waiting GetVirtText|nil Waiting/loading state (optional, falls back to text)
---@field waiting_animated GetVirtTextAnimated|nil Animated waiting state (optional)
---@field should_animate ShouldAnimateFunc|nil Condition to enable animation (default: always)
---@field animation_interval number|nil Milliseconds between animation frames (default: 150)
local InlineAdornerFormatter = setmetatable({}, { __index = FormatterBase })
InlineAdornerFormatter.__index = InlineAdornerFormatter

---@class InlineAdornerOptions : SymbolAdornerOpions
-- • align : position of virtual text. Possible values:
--     • "eol": right after eol character (default).
--     • "eol_right_align": display right aligned in the window
--         unless the virtual text is longer than the space
--         available. If the virtual text is too long, it is
--         truncated to fit in the window after the EOL character.
--         If the line is wrapped, the virtual text is shown after
--         the end of the line rather than the previous screen
--         line.
--     • "overlay": display over the specified symbol, without
--         shifting the underlying text.
--     • "right_align": display right aligned in the window.
--     • "before": text placed before symbol
--     • "after": text placed after symbol
---@field align? string
-- • hl_mode : control how highlights are combined with the
--     highlights of the text. Currently only affects virt_text
--     highlights, but might affect `hl_group` in later versions.
--     • "replace": only show the virt_text color. This is the
--         default.
--     • "combine": combine with background text color.
--     • "blend": blend with background text color. Not supported
--     for "before" and "after" align.
---@field hl_mode? string
---@field formatter? InlineAdornerFormatter | string Formatter (instance or name to look up)

---@class InlineAdorner : SymbolAdorner
---@field formatter InlineAdornerFormatter  -- Describes how this adorner renders symbols
---@field set_virtual_text SetVirtualTextFunc  -- Field in the class
---@field align integer
local InlineAdorner = setmetatable({}, {__index = SymbolAdorner})
InlineAdorner.__index = InlineAdorner

---@class SymbolInfoRef : SymbolInfo
---@field old_refs integer  -- Field in the class

-- ============================================================================
-- InlineAdornerFormatter Class
-- ============================================================================

---Create a new formatter descriptor
---@param opts {text: GetVirtText, text_animated?: GetVirtTextAnimated, waiting?: GetVirtText, waiting_animated?: GetVirtTextAnimated, should_animate?: ShouldAnimateFunc, animation_interval?: number}
---@return InlineAdornerFormatter
function InlineAdornerFormatter:new(opts)
    local instance = FormatterBase.new(self, opts)
    return setmetatable(instance, InlineAdornerFormatter)
end

--- Format inline virtual text for a symbol using cached formatter
--- Assumes adorner_data.format_func was set by set_symbol_state()
---@param adorner InlineAdorner
---@param symbol SymbolInfo
---@param adorner_data any Symbol-specific adorner data (must contain format_func and is_animated)
---@return any[]|nil virt_text Virtual text chunks
function InlineAdornerFormatter:format_symbol(adorner, symbol, adorner_data)
    local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
    local mark_core = symbol[SymbolInfo.CORE]

    -- Use cached formatter function (set by set_symbol_state)
    local format_func = adorner_data.format_func
    local is_animated = adorner_data.is_animated

    -- Call with appropriate parameters based on whether it's animated
    if is_animated then
        local time = adorner_data.animation_time or 0
        return format_func(adorner, mark_core.line, mark_core.col, symbol, adorner_data, time)
    else
        return format_func(adorner, mark_core.line, mark_core.col, symbol, adorner_data)
    end
end

-- ============================================================================
-- Formatter Presets
-- ============================================================================

-- Formatter presets initialization (populated from presets file at end of module)
---@type table<string, InlineAdornerFormatter>
InlineAdorner.formatters = {}

-- ============================================================================
-- Helper Functions
-- ============================================================================

--- Update visual extmark for a symbol
---@param adorner InlineAdorner
---@param _watcher SymbolsWatcher
---@param symbol SymbolInfo
---@diagnostic disable-next-line: unused-local
local function update_visual_ext_mark(adorner, _watcher, symbol)
    local mark_core = symbol[SymbolInfo.CORE]
    local adorner_data = SymbolInfo.get_adorner_data(symbol, adorner)
    local formatter = adorner.formatter

    -- Format virtual text using cached formatter function (cached by OnSymbolDataUpdated event)
    local virt_text = formatter:format_symbol(adorner, symbol, adorner_data)

    if not virt_text then return end

    local col = mark_core.col
    if adorner.align == 1 then
        col = SymbolsWatcher.get_symbol_end_col(symbol)
    end

    local visual_mark_id = adorner_data.visual_mark_id
    if not visual_mark_id then
        -- Create new visual mark
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, adorner.watcher.buffer, adorner.watcher.namespace, mark_core.line, col, {
            virt_text = virt_text,
            virt_text_pos = adorner.virt_text_pos,
            hl_mode = adorner.hl_mode,
        })

        if ok then
            logger.debug("Visual mark created: symbol=%s id=%d", SymbolInfo.id_pos_to_string(symbol), id)
            adorner_data.visual_mark_id = id
        end
    else
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, adorner.watcher.buffer, adorner.watcher.namespace, mark_core.line, col, {
            id = visual_mark_id,
            virt_text = virt_text,
            virt_text_pos = adorner.virt_text_pos,
            hl_mode = adorner.hl_mode,
        })

        -- print(vim.inspect({
        --     id = adorner_data,
        --     virt_text = virt_text,
        --     virt_text_pos = adorner.virt_text_pos,
        --     hl_mode = adorner.hl_mode,
        -- }))

        if ok then
            adorner_data.visual_mark_id = id
            logger.debug("Visual mark changed: symbol=%s id=%d", SymbolInfo.id_pos_to_string(symbol), id)
        else
            logger.error("Error creating visual mark: %s data=%s", SymbolInfo.pos_to_string(symbol), vim.inspect(symbol))

        end
    end
end

--- Manage per-symbol animation callback registration
--- Registers callback when is_animated = true, removes when false
---@param self InlineAdorner
---@param symbol SymbolInfo
---@param adorner_data table Symbol's adorner data
local function manage_symbol_animation(self, symbol, adorner_data)
    local is_animated = adorner_data.is_animated
    local has_callback = adorner_data.animation_cleanup ~= nil

    if is_animated and not has_callback then
        -- Start animation: register callback
        local interval = self.formatter.animation_interval or 150

        adorner_data.animation_cleanup = AnimationManager.add_animated_callback(function(now)
            local last_update = adorner_data.animation_last_update or 0

            if now - last_update >= interval then
                -- Increment animation time
                adorner_data.animation_time = (adorner_data.animation_time or 0) + interval
                adorner_data.animation_last_update = now

                -- Update extmark
                update_visual_ext_mark(self, self.watcher, symbol)
            end
        end)

    elseif not is_animated and has_callback then
        -- Stop animation: unregister callback
        adorner_data.animation_cleanup()
        adorner_data.animation_cleanup = nil
        adorner_data.animation_time = nil
        adorner_data.animation_last_update = nil

        -- Force update to show normal formatter
        update_visual_ext_mark(self, self.watcher, symbol)
    end
end

-- ============================================================================
-- InlineAdorner Main Class
-- ============================================================================

---@param  watcher SymbolsWatcher
function InlineAdorner:new(watcher)
    return SymbolAdorner.new(self, watcher)
end

---@param  opts InlineAdornerOptions
function InlineAdorner:init(opts, index, kinds_mask)
    SymbolAdorner.init(self, opts, index,kinds_mask)
    self.hl_group = require("referencer.config").get_hl_group()

    -- Resolve formatter: string → lookup, instance → use directly
    if type(opts.formatter) == "string" then
        -- Look up predefined formatter by name
        self.formatter = InlineAdorner.formatters[opts.formatter] or InlineAdorner.formatters.refs
    elseif opts.formatter and getmetatable(opts.formatter) == InlineAdornerFormatter then
        -- Already an InlineAdornerFormatter instance (metatable check)
        local formatter_instance = opts.formatter
        ---@cast formatter_instance InlineAdornerFormatter
        self.formatter = formatter_instance
    else
        -- Default formatter (nil or unexpected type)
        self.formatter = InlineAdorner.formatters.refs
    end

    -- Animation option removed - animations are now built into formatters
    if opts.animation then
        logger.error("opts.animation is no longer supported. Use formatter presets instead (e.g., 'refs_waiting_star_pulse')")
    end

    self.virt_text_pos = opts.align or "eol"
    self.hl_mode = opts.hl_mode or "replace"
    self.align = opts.align == "after" and 1 or 0

    if opts.align == "eol" or
        opts.align == "eol_right_align" or
        opts.align == "overlay" or
        opts.align == "right_align"
    then
        self.virt_text_pos = opts.align
    else
        if opts.hl_mode == "blend" then
            vim.notify("hl_mode blend is not supported for aligns: 'before' and 'after'")
        end
        self.virt_text_pos = "inline"
    end

    self:Enable()
end

---@param  mark SymbolInfo
function InlineAdorner:destroy_mark(mark)
    local adorner_data = SymbolInfo.get_adorner_data(mark, self)
    local visual_mark_id = adorner_data.visual_mark_id
    if visual_mark_id then
        -- visual mark is created yet
        local ok = pcall(vim.api.nvim_buf_del_extmark, self.watcher.buffer, self.watcher.namespace, visual_mark_id)
        if ok then
            logger.debug("Visual mark destroyed: %s mark_id=%d", SymbolInfo.pos_to_string(mark), visual_mark_id)
        end
        adorner_data.visual_mark_id = nil
    end
end

---@param line integer
---@param col integer
function InlineAdorner:inspect_position(line, col)
    local line_info = self.watcher.lines[line]
    if line_info then
        logger.debug("inspect_position: line=%d col=%d symbols_count=%d", line, col, #line_info.symbols)
        for i, symbol_info in ipairs(line_info.symbols) do
            local s_col = SymbolInfo.get_col(symbol_info)
            local s_end_col = SymbolInfo.get_end_col(symbol_info)
            logger.debug("  symbol %d: col=%d-%d", i, s_col, s_end_col)
            if col >= s_col and col <= s_end_col then
                logger.debug("  -> MATCH! Flashing symbol")
                utils.flash_extmark(self.watcher.buffer, line, s_col, s_end_col)
                local text = vim.inspect(SymbolInfo.get_symbol_data(symbol_info))
                local lines = vim.split(text, '\n')
                utils.show_hover_at(lines, line + 3, s_end_col + 2)
            end
        end
    end
end

function InlineAdorner:Enable()
    -- self.watcher.OnLineCreated:subscribe(function (args)
    -- end)
    --

    ---@param args SymbolEventArgs
    self:AddUnsubHook(self.watcher.OnSymbolDataUpdated:subscribe(function (args)
        if self:is_symbol_supported(args.symbol) then
            -- Update cached formatter based on new symbol state (waiting vs normal)
            local adorner_data = SymbolInfo.get_adorner_data(args.symbol, self)
            self.formatter:set_symbol_state(adorner_data, args.symbol)

            -- Manage animation callback registration based on is_animated state
            manage_symbol_animation(self, args.symbol, adorner_data)

            update_visual_ext_mark(self, self.watcher, args.symbol)
        end
    end))

    ---@param symbol SymbolInfo
    self:AddUnsubHook(self.watcher.OnSymbolMarkChanged:subscribe(function (symbol)
        if self:is_symbol_supported(symbol) then
            -- Update formatter state when symbol mark changes (validated_tick may have changed)
            local adorner_data = SymbolInfo.get_adorner_data(symbol, self)
            self.formatter:set_symbol_state(adorner_data, symbol)

            -- Manage animation callback registration based on is_animated state
            manage_symbol_animation(self, symbol, adorner_data)

            update_visual_ext_mark(self, self.watcher, symbol)
        end
    end))

    self:AddUnsubHook(self.watcher.OnActualizeCancelled:subscribe(function ()
        for _, mark in pairs(self.watcher.new_symbols) do
            self:destroy_mark(mark)
        end
    end))

    ---@param args SymbolInfo
    self:AddUnsubHook(self.watcher.OnSymbolMarkDestroyed:subscribe(function (args)
            self:destroy_mark(args)
    end))

    -- Note: Animation is now managed per-symbol via manage_symbol_animation()
    -- Callbacks are registered dynamically when symbols need animation
end

-- ============================================================================
-- Module Exports
-- ============================================================================

-- Load formatter presets from separate file
local create_formatters = require("referencer.adorners.inline-adorner-presets")
InlineAdorner.formatters = create_formatters(InlineAdornerFormatter)

-- Export the formatter class for user customization
InlineAdorner.Formatter = InlineAdornerFormatter

return InlineAdorner
