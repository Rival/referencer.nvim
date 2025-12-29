--- Base formatter class shared between InlineAdorner and VirtualLinesAdorner
--- Encapsulates variant selection logic (text/waiting × static/animated)
local config = require("referencer.config")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")

---@class FormatterBase
---@field text function Normal state formatter (required)
---@field text_animated function|nil Animated normal state (optional)
---@field waiting function|nil Waiting/loading state (optional, falls back to text)
---@field waiting_animated function|nil Animated waiting state (optional)
---@field should_animate function|nil Callback: (symbol, adorner_data) -> boolean (default: animate when waiting)
---@field animation_interval number Milliseconds between animation frames (default: 150)
local FormatterBase = {}
FormatterBase.__index = FormatterBase

---Create a new formatter instance
---@param opts {text: function, text_animated?: function, waiting?: function, waiting_animated?: function, should_animate?: function, animation_interval?: number}
---@return FormatterBase
function FormatterBase:new(opts)
    return setmetatable({
        text = opts.text,
        text_animated = opts.text_animated,
        waiting = opts.waiting,
        waiting_animated = opts.waiting_animated,
        should_animate = opts.should_animate,
        animation_interval = opts.animation_interval or 150,
    }, self)
end

--- Select appropriate formatter variant based on state
--- Encapsulates the fallback chain: waiting_animated → waiting → text_animated → text
---@param symbol SymbolInfo
---@param adorner_data table Adorner-specific symbol data
---@param time number Animation time (milliseconds since animation started)
---@return function format_func The selected formatter function
---@return boolean should_animate Whether the selected formatter expects time parameter
function FormatterBase:select_variant(symbol, adorner_data, time)
    local is_waiting = SymbolInfo.get_validated_tick(symbol) == 0
    local animations_enabled = config.options.animations_enabled ~= false
    local should_animate = false

    if animations_enabled then
        if self.should_animate then
            should_animate = self.should_animate(symbol, adorner_data)
        else
            -- Default: animate when waiting/not validated
            should_animate = is_waiting
        end
    end

    -- Select appropriate formatter variant (priority order)
    local format_func
    if is_waiting then
        if should_animate and self.waiting_animated then
            format_func = self.waiting_animated
        elseif self.waiting then
            format_func = self.waiting
        elseif should_animate and self.text_animated then
            format_func = self.text_animated
        else
            format_func = self.text
        end
    else
        if should_animate and self.text_animated then
            format_func = self.text_animated
        else
            format_func = self.text
        end
    end

    return format_func, should_animate and (format_func == self.text_animated or format_func == self.waiting_animated)
end

--- Update cached formatter function based on symbol state
--- Caches selected function in adorner_data for fast rendering
---@param adorner_data table Adorner-specific symbol data (will be modified)
---@param symbol SymbolInfo Symbol to determine state from
function FormatterBase:set_symbol_state(adorner_data, symbol)
    -- Determine symbol state
    local is_waiting = SymbolInfo.get_validated_tick(symbol) == 0
    local animations_enabled = config.options.animations_enabled ~= false
    local should_animate = false

    if animations_enabled then
        if self.should_animate then
            should_animate = self.should_animate(symbol, adorner_data)
        else
            -- Default: animate when waiting/not validated
            should_animate = is_waiting
        end
    end

    -- Select and cache formatter function
    local format_func
    if is_waiting then
        if should_animate and self.waiting_animated then
            format_func = self.waiting_animated
            adorner_data.is_animated = true
        elseif self.waiting then
            format_func = self.waiting
            adorner_data.is_animated = false
        elseif should_animate and self.text_animated then
            format_func = self.text_animated
            adorner_data.is_animated = true
        else
            format_func = self.text
            adorner_data.is_animated = false
        end
    else
        if should_animate and self.text_animated then
            format_func = self.text_animated
            adorner_data.is_animated = true
        else
            format_func = self.text
            adorner_data.is_animated = false
        end
    end

    -- Cache selected function and state
    adorner_data.format_func = format_func
    adorner_data.symbol_mode = is_waiting and "waiting" or "normal"
end

--- Update formatter when symbol's index changes
--- Default implementation does nothing (only FirstAndOthersFormatter needs this)
---@param adorner_data table Adorner-specific symbol data (will be modified)
---@param symbol SymbolInfo Symbol to update formatter for
---@param index integer New 1-based index on line
function FormatterBase:set_symbol_index(adorner_data, symbol, index)
    -- Default: no-op, most formatters don't care about index
end

return FormatterBase
