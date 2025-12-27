local config = require("referencer.config")
local utils = require("referencer.utils")
local SymbolAdorner = require("referencer.adorners.symbol-adorner")
local SymbolsWatcher = require("referencer.symbols-watcher.symbols-watcher")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local logger = require("referencer.logger").for_module("inline_adorner")

---@alias GetVirtTextAnimated fun(adorner:InlineAdorner, line:integer, col:integer, symbol_info:SymbolInfo, adorner_data:any, time:number):any[]|nil, integer
---@alias ShouldAnimateFunc fun(symbol:SymbolInfo, adorner_data:any):boolean

---@class InlineAdornerFormatter
---@field text GetVirtText Normal state formatter
---@field text_animated GetVirtTextAnimated|nil Animated normal state (optional, falls back to text)
---@field waiting GetVirtText|nil Waiting/loading state (optional, falls back to text)
---@field waiting_animated GetVirtTextAnimated|nil Animated waiting state (optional)
---@field should_animate ShouldAnimateFunc|nil Condition to enable animation (default: always)
---@field animation_interval number|nil Milliseconds between animation frames (default: 150)
local InlineAdornerFormatter = {}
InlineAdornerFormatter.__index = InlineAdornerFormatter

---Create a new formatter descriptor
---@param opts {text: GetVirtText, text_animated?: GetVirtTextAnimated, waiting?: GetVirtText, waiting_animated?: GetVirtTextAnimated, should_animate?: ShouldAnimateFunc, animation_interval?: number}
---@return InlineAdornerFormatter
function InlineAdornerFormatter:new(opts)
    return setmetatable({
        text = opts.text,
        text_animated = opts.text_animated,
        waiting = opts.waiting,
        waiting_animated = opts.waiting_animated,
        should_animate = opts.should_animate,
        animation_interval = opts.animation_interval or 150,
    }, self)
end

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

---@alias SetVirtualTextFunc fun(adorner:InlineAdorner, watcher:SymbolsWatcher, line:integer, col: integer, symbol_data: SymbolData)
---@alias GetVirtText fun(watcher:InlineAdorner, line:integer, col: integer, symbol_info: SymbolInfo, adorner_data: any):any[]|nil, integer

-- Load formatter presets from separate file
-- Built-in formatters (each is an InlineAdornerFormatter instance)
---@type table<string, InlineAdornerFormatter>
InlineAdorner.formatters = {}

---@param symbol SymbolInfo
---@param adorner InlineAdorner
---@diagnostic disable-next-line: unused-local
local function update_visual_ext_mark(adorner, _watcher, symbol)
    local mark_core = symbol[SymbolInfo.CORE]
    local adorner_data = SymbolInfo.get_adorner_data(symbol, adorner)
    local formatter = adorner.formatter

    local virt_text

    -- Determine state: waiting (not validated) vs normal
    local is_waiting = SymbolInfo.get_validated_tick(symbol) == 0

    -- Check if animations are enabled globally and for this formatter
    local animations_enabled = config.options.animations_enabled ~= false
    local should_animate = false

    if animations_enabled then
        if formatter.should_animate then
            should_animate = formatter.should_animate(symbol, adorner_data)
        else
            -- Default: animate when waiting/not validated
            should_animate = is_waiting
        end
    end

    -- Select appropriate formatter function with fallback chain
    local format_func
    local time = adorner_data.animation_time or 0

    if is_waiting then
        if should_animate and formatter.waiting_animated then
            format_func = function() return formatter.waiting_animated(adorner, mark_core.line, mark_core.col, symbol, adorner_data, time) end
        elseif formatter.waiting then
            format_func = function() return formatter.waiting(adorner, mark_core.line, mark_core.col, symbol, adorner_data) end
        elseif should_animate and formatter.text_animated then
            format_func = function() return formatter.text_animated(adorner, mark_core.line, mark_core.col, symbol, adorner_data, time) end
        else
            format_func = function() return formatter.text(adorner, mark_core.line, mark_core.col, symbol, adorner_data) end
        end
    else
        if should_animate and formatter.text_animated then
            format_func = function() return formatter.text_animated(adorner, mark_core.line, mark_core.col, symbol, adorner_data, time) end
        else
            format_func = function() return formatter.text(adorner, mark_core.line, mark_core.col, symbol, adorner_data) end
        end
    end

    virt_text = format_func()

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
function SymbolAdorner:inspect_position(line, col)
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

---Update animation time for symbols that need animation
function InlineAdorner:update_animations()
    local formatter = self.formatter

    -- Skip if no animated formatters configured
    if not formatter.text_animated and not formatter.waiting_animated then
        return
    end

    -- Check if animations are globally enabled
    if config.options.animations_enabled == false then
        return
    end

    local now = vim.loop.now()
    local needs_update = {}
    local interval = formatter.animation_interval or 150

    for _, line_info in pairs(self.watcher.lines) do
        for _, symbol in ipairs(line_info.symbols) do
            if not self:is_symbol_supported(symbol) then goto continue end

            local adorner_data = SymbolInfo.get_adorner_data(symbol, self)

            -- Determine if this symbol should animate
            local should_animate = false
            if formatter.should_animate then
                should_animate = formatter.should_animate(symbol, adorner_data)
            else
                -- Default: animate when waiting/not validated
                should_animate = SymbolInfo.get_validated_tick(symbol) == 0
            end

            if should_animate then
                local last_update = adorner_data.animation_last_update or 0

                if now - last_update >= interval then
                    -- Increment animation time (ms since animation started)
                    adorner_data.animation_time = (adorner_data.animation_time or 0) + interval
                    adorner_data.animation_last_update = now
                    table.insert(needs_update, symbol)
                end
            else
                -- Not animating anymore, reset state
                if adorner_data.animation_time ~= nil then
                    adorner_data.animation_time = nil
                    adorner_data.animation_last_update = nil
                    -- Force update to show normal formatter
                    table.insert(needs_update, symbol)
                end
            end

            ::continue::
        end
    end

    -- Update extmarks for symbols that changed
    for _, symbol in ipairs(needs_update) do
        update_visual_ext_mark(self, self.watcher, symbol)
    end
end

function InlineAdorner:Enable()
    -- self.watcher.OnLineCreated:subscribe(function (args)
    -- end)
    --

    ---@param args SymbolEventArgs
    self:AddUnsubHook(self.watcher.OnSymbolDataUpdated:subscribe(function (args)
        if self:is_symbol_supported(args.symbol) then
            update_visual_ext_mark(self, self.watcher, args.symbol)
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

    -- Animation timer for loading states (runs every 50ms)
    self.animation_timer = vim.loop.new_timer()
    self.animation_timer:start(50, 50, vim.schedule_wrap(function()
        self:update_animations()
    end))

    -- Clean up timer when adorner is disabled
    self:AddUnsubHook(function()
        if self.animation_timer then
            self.animation_timer:stop()
            self.animation_timer:close()
            self.animation_timer = nil
        end
    end)

    -- self.watcher.OnActualizeEnd:subscribe(function (args)
    --
    -- end)
end

-- ============================================================================
-- LOAD FORMATTER PRESETS
-- ============================================================================

-- Load formatter presets from separate file
local create_formatters = require("referencer.adorners.inline-adorner-presets")
InlineAdorner.formatters = create_formatters(InlineAdornerFormatter)

-- Export the formatter class for user customization
InlineAdorner.Formatter = InlineAdornerFormatter

return InlineAdorner
