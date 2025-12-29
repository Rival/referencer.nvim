-- ============================================================================
-- Virtual Lines Formatters
-- ============================================================================
-- Formatter classes and factory for virtual-lines-adorner
-- Handles different formatting strategies: single, first_and_following, position, selector

local FormatterBase = require("referencer.adorners.formatter-base")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local logger = require("referencer.logger").for_module("virtual_lines_formatters")

local M = {}

-- ============================================================================
-- VirtualLineFormatter (Base Class)
-- ============================================================================

---@class VirtualLineFormatter : FormatterBase
---@field text GetVirtualTextBySymbol Normal state formatter
---@field text_animated GetVirtualTextBySymbolAnimated|nil Animated normal state
---@field waiting GetVirtualTextBySymbol|nil Waiting/loading state
---@field waiting_animated GetVirtualTextBySymbolAnimated|nil Animated waiting state
---@field should_animate ShouldAnimateVirtualLineFunc|nil Condition to enable animation
---@field animation_interval number|nil Milliseconds between frames (default: 150)
---@field set_symbol_state fun(self: VirtualLineFormatter, adorner_data: table, symbol: SymbolInfo) Inherited from FormatterBase - caches format_func based on symbol state
---@field set_symbol_index fun(self: VirtualLineFormatter, adorner_data: table, symbol: SymbolInfo, index: integer) Inherited from FormatterBase - updates formatter when index changes
local VirtualLineFormatter = setmetatable({}, { __index = FormatterBase })
VirtualLineFormatter.__index = VirtualLineFormatter

function VirtualLineFormatter:new(opts)
    local instance = FormatterBase.new(self, opts)
    return setmetatable(instance, VirtualLineFormatter)
end

--- Format virtual line text for a symbol using cached formatter
--- Assumes adorner_data.format_func was set by set_symbol_state()
---@param adorner VirtualLinesAdorner
---@param line integer
---@param span_start_col integer
---@param span_end_col integer
---@param symbol_col integer
---@param symbol_end_col integer
---@param symbol SymbolInfo
---@param adorner_data VirtualLinesSymbolAdornerData Must contain format_func and is_animated fields
---@param line_data VirtualLineData Line-level data (contains animation_time)
---@return string|nil text Formatted text
---@return integer target_col Target column position
function VirtualLineFormatter:format_symbol(adorner, line, span_start_col, span_end_col,
                                            symbol_col, symbol_end_col, symbol, adorner_data, line_data)
    -- Use cached formatter function (set by set_symbol_state)
    local format_func = adorner_data.format_func
    local is_animated = adorner_data.is_animated

    -- Call with appropriate parameters based on whether it's animated
    if is_animated then
        local time = line_data.animation_time or 0
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data, time)
    else
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data)
    end
end

M.VirtualLineFormatter = VirtualLineFormatter

-- ============================================================================
-- FirstAndOthersFormatter - Different formatter for first vs following symbols
-- ============================================================================

---@class FirstAndOthersFormatter : VirtualLineFormatter
---@field first_formatter VirtualLineFormatter Formatter for first symbol on line
---@field following_formatter VirtualLineFormatter Formatter for subsequent symbols
local FirstAndOthersFormatter = setmetatable({}, { __index = VirtualLineFormatter })
FirstAndOthersFormatter.__index = FirstAndOthersFormatter

--- Create a composite formatter that delegates based on symbol position
---@param first_formatter VirtualLineFormatter Formatter for first symbol
---@param following_formatter VirtualLineFormatter Formatter for following symbols
---@return FirstAndOthersFormatter
function FirstAndOthersFormatter:new(first_formatter, following_formatter)
    return setmetatable({
        first_formatter = first_formatter,
        following_formatter = following_formatter,
    }, self)
end

--- Get the appropriate delegate formatter based on symbol index
--- Encapsulates access to internal formatter fields
---@param symbol_index integer Symbol position on line (1-based)
---@return VirtualLineFormatter
function FirstAndOthersFormatter:get_delegate(symbol_index)
    return symbol_index == 1 and self.first_formatter or self.following_formatter
end

--- Update cached formatter by delegating to appropriate formatter based on symbol index
--- Caches only the current formatter (first or following) based on symbol's index
---@param adorner_data VirtualLinesSymbolAdornerData Will be populated with cached format func
---@param symbol SymbolInfo
function FirstAndOthersFormatter:set_symbol_state(adorner_data, symbol)
    local index = SymbolInfo.get_index(symbol)

    -- Select appropriate delegate based on current index
    local formatter = (index == 1) and self.first_formatter or self.following_formatter

    -- Cache the selected formatter's state
    formatter:set_symbol_state(adorner_data, symbol)
end

--- Re-cache formatter when symbol's position on line changes
--- This handles when a symbol becomes first/following due to insertions/deletions
---@param adorner_data VirtualLinesSymbolAdornerData Will be updated with new cached formatter
---@param symbol SymbolInfo
---@param index integer New 1-based index on line
function FirstAndOthersFormatter:set_symbol_index(adorner_data, symbol, index)
    -- Select appropriate delegate based on new index
    local formatter = (index == 1) and self.first_formatter or self.following_formatter

    -- Re-cache the formatter for the new position
    formatter:set_symbol_state(adorner_data, symbol)
end

--- Format by using cached formatter (set by set_symbol_state or set_symbol_index)
--- Now simplified since we only cache one formatter at a time
---@param adorner VirtualLinesAdorner
---@param line integer
---@param span_start_col integer
---@param span_end_col integer
---@param symbol_col integer
---@param symbol_end_col integer
---@param symbol SymbolInfo
---@param adorner_data VirtualLinesSymbolAdornerData Must contain cached format_func from set_symbol_state
---@param line_data VirtualLineData
---@return string|nil text
---@return integer target_col
function FirstAndOthersFormatter:format_symbol(adorner, line, span_start_col, span_end_col,
                                               symbol_col, symbol_end_col, symbol, adorner_data, line_data)
    -- Use the cached formatter (already selected based on current index)
    local format_func = adorner_data.format_func
    local is_animated = adorner_data.is_animated

    if is_animated then
        local time = line_data.animation_time or 0
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data, time)
    else
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data)
    end
end

M.FirstAndOthersFormatter = FirstAndOthersFormatter

-- ============================================================================
-- SingleFormatter - Uses same formatter for all symbols
-- ============================================================================

---@class SingleFormatter : VirtualLineFormatter
---@field formatter VirtualLineFormatter The formatter to use for all symbols
local SingleFormatter = setmetatable({}, { __index = VirtualLineFormatter })
SingleFormatter.__index = SingleFormatter

---@param formatter VirtualLineFormatter
---@return SingleFormatter
function SingleFormatter:new(formatter)
    return setmetatable({
        formatter = formatter,
    }, self)
end

---@param adorner_data VirtualLinesSymbolAdornerData
---@param symbol SymbolInfo
function SingleFormatter:set_symbol_state(adorner_data, symbol)
    self.formatter:set_symbol_state(adorner_data, symbol)
end

---@param adorner_data VirtualLinesSymbolAdornerData
---@param symbol SymbolInfo
---@param index integer
function SingleFormatter:set_symbol_index(adorner_data, symbol, index)
    -- No-op: single formatter doesn't care about index
end

---@param adorner VirtualLinesAdorner
---@param line integer
---@param span_start_col integer
---@param span_end_col integer
---@param symbol_col integer
---@param symbol_end_col integer
---@param symbol SymbolInfo
---@param adorner_data VirtualLinesSymbolAdornerData
---@param line_data VirtualLineData
---@return string|nil text
---@return integer target_col
function SingleFormatter:format_symbol(adorner, line, span_start_col, span_end_col,
                                       symbol_col, symbol_end_col, symbol, adorner_data, line_data)
    return self.formatter:format_symbol(adorner, line, span_start_col, span_end_col,
                                        symbol_col, symbol_end_col, symbol, adorner_data, line_data)
end

M.SingleFormatter = SingleFormatter

-- ============================================================================
-- PositionFormatter - Array-based formatter lookup by symbol index
-- ============================================================================

---@class PositionFormatter : VirtualLineFormatter
---@field formatters table<integer, VirtualLineFormatter> Position-specific formatters (1-based)
---@field default VirtualLineFormatter Fallback formatter
local PositionFormatter = setmetatable({}, { __index = VirtualLineFormatter })
PositionFormatter.__index = PositionFormatter

---@param formatters table<integer, VirtualLineFormatter>
---@param default VirtualLineFormatter
---@return PositionFormatter
function PositionFormatter:new(formatters, default)
    return setmetatable({
        formatters = formatters,
        default = default,
    }, self)
end

---@param index integer
---@return VirtualLineFormatter
function PositionFormatter:get_formatter(index)
    return self.formatters[index] or self.default
end

---@param adorner_data VirtualLinesSymbolAdornerData
---@param symbol SymbolInfo
function PositionFormatter:set_symbol_state(adorner_data, symbol)
    local index = SymbolInfo.get_index(symbol)
    local formatter = self:get_formatter(index)
    formatter:set_symbol_state(adorner_data, symbol)
end

---@param adorner_data VirtualLinesSymbolAdornerData
---@param symbol SymbolInfo
---@param index integer
function PositionFormatter:set_symbol_index(adorner_data, symbol, index)
    local formatter = self:get_formatter(index)
    formatter:set_symbol_state(adorner_data, symbol)
end

---@param adorner VirtualLinesAdorner
---@param line integer
---@param span_start_col integer
---@param span_end_col integer
---@param symbol_col integer
---@param symbol_end_col integer
---@param symbol SymbolInfo
---@param adorner_data VirtualLinesSymbolAdornerData
---@param line_data VirtualLineData
---@return string|nil text
---@return integer target_col
function PositionFormatter:format_symbol(adorner, line, span_start_col, span_end_col,
                                         symbol_col, symbol_end_col, symbol, adorner_data, line_data)
    local format_func = adorner_data.format_func
    local is_animated = adorner_data.is_animated

    if is_animated then
        local time = line_data.animation_time or 0
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data, time)
    else
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data)
    end
end

M.PositionFormatter = PositionFormatter

-- ============================================================================
-- SelectorFormatter - Custom function-based formatter selection
-- ============================================================================

---@class SelectorFormatter : VirtualLineFormatter
---@field selector FormatterSelectorFunc User function that returns formatter based on symbol/index
---@field formatter_cache table<string, VirtualLineFormatter> Cache of resolved formatters
---@field formatters_registry table<string, VirtualLineFormatter> Reference to VirtualLinesAdorner.formatters
local SelectorFormatter = setmetatable({}, { __index = VirtualLineFormatter })
SelectorFormatter.__index = SelectorFormatter

---@param selector FormatterSelectorFunc
---@param formatters_registry table<string, VirtualLineFormatter>
---@return SelectorFormatter
function SelectorFormatter:new(selector, formatters_registry)
    return setmetatable({
        selector = selector,
        formatter_cache = {},
        formatters_registry = formatters_registry or {},
    }, self)
end

--- Resolve formatter name/instance/function to VirtualLineFormatter
---@param formatter_spec string|VirtualLineFormatter|GetVirtualTextBySymbol
---@return VirtualLineFormatter
function SelectorFormatter:resolve_formatter(formatter_spec)
    if type(formatter_spec) == "string" then
        -- Look up by name
        if not self.formatter_cache[formatter_spec] then
            self.formatter_cache[formatter_spec] = self.formatters_registry[formatter_spec]
                or self.formatters_registry.refs_most_left
        end
        ---@diagnostic disable-next-line: return-type-mismatch
        return self.formatter_cache[formatter_spec]
    elseif getmetatable(formatter_spec) == VirtualLineFormatter then
        ---@diagnostic disable-next-line: return-type-mismatch
        return formatter_spec
    elseif type(formatter_spec) == "function" then
        -- Wrap function in formatter
        local cache_key = tostring(formatter_spec)
        if not self.formatter_cache[cache_key] then
            ---@diagnostic disable-next-line: assign-type-mismatch
            self.formatter_cache[cache_key] = VirtualLineFormatter:new({ text = formatter_spec })
        end
        ---@diagnostic disable-next-line: return-type-mismatch
        return self.formatter_cache[cache_key]
    else
        return self.formatters_registry.refs_most_left
    end
end

---@param adorner_data VirtualLinesSymbolAdornerData
---@param symbol SymbolInfo
function SelectorFormatter:set_symbol_state(adorner_data, symbol)
    local index = SymbolInfo.get_index(symbol)
    -- TODO: SelectorFormatter needs access to watcher to get line_info
    -- For now, pass nil - selector functions should handle this gracefully
    ---@diagnostic disable-next-line: undefined-field
    local line_info = nil

    -- Call user selector to get formatter spec
    ---@diagnostic disable-next-line: param-type-mismatch
    local formatter_spec = self.selector(symbol, index, line_info)
    local formatter = self:resolve_formatter(formatter_spec)

    -- Cache the formatter in adorner_data
    formatter:set_symbol_state(adorner_data, symbol)
end

---@param adorner_data VirtualLinesSymbolAdornerData
---@param symbol SymbolInfo
---@param index integer
function SelectorFormatter:set_symbol_index(adorner_data, symbol, _index)
    -- Re-run selector with new index
    self:set_symbol_state(adorner_data, symbol)
end

---@param adorner VirtualLinesAdorner
---@param line integer
---@param span_start_col integer
---@param span_end_col integer
---@param symbol_col integer
---@param symbol_end_col integer
---@param symbol SymbolInfo
---@param adorner_data VirtualLinesSymbolAdornerData
---@param line_data VirtualLineData
---@return string|nil text
---@return integer target_col
function SelectorFormatter:format_symbol(adorner, line, span_start_col, span_end_col,
                                         symbol_col, symbol_end_col, symbol, adorner_data, line_data)
    local format_func = adorner_data.format_func
    local is_animated = adorner_data.is_animated

    if is_animated then
        local time = line_data.animation_time or 0
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data, time)
    else
        return format_func(adorner, line, span_start_col, span_end_col,
                          symbol_col, symbol_end_col, symbol, adorner_data)
    end
end

M.SelectorFormatter = SelectorFormatter

-- ============================================================================
-- Formatter Factory
-- ============================================================================

--- Resolve formatter spec to VirtualLineFormatter instance
---@param spec string|VirtualLineFormatter|GetVirtualTextBySymbol
---@param formatters_registry table<string, VirtualLineFormatter>
---@return VirtualLineFormatter
local function resolve_formatter_spec(spec, formatters_registry)
    if type(spec) == "string" then
        return formatters_registry[spec] or formatters_registry.refs_most_left
    elseif getmetatable(spec) == VirtualLineFormatter then
        ---@diagnostic disable-next-line: return-type-mismatch
        return spec
    elseif type(spec) == "function" then
        ---@diagnostic disable-next-line: return-type-mismatch
        return VirtualLineFormatter:new({ text = spec })
    else
        return formatters_registry.refs_most_left
    end
end

--- Create formatter based on configuration
---@param opts VirtualLineAdornerOptions
---@param formatters_registry table<string, VirtualLineFormatter> Registry of named formatters
---@return VirtualLineFormatter
function M.create_formatter(opts, formatters_registry)
    formatters_registry = formatters_registry or {}

    -- ========================================================================
    -- Formatter Configuration Resolution
    -- ========================================================================
    -- Priority:
    --   1. opts.formatter (new flexible config)
    --   2. opts.align_first/align_following (deprecated, backward compatibility)
    --   3. Default to single formatter: refs_most_left

    if opts.formatter then
        local formatter_cfg = opts.formatter

        -- Case 1: Simple direct formatter (string, instance, or function)
        if type(formatter_cfg) == "string" or
           type(formatter_cfg) == "function" or
           getmetatable(formatter_cfg) == VirtualLineFormatter then
            -- Treat as single formatter for all symbols
            ---@diagnostic disable-next-line: param-type-mismatch
            local formatter = resolve_formatter_spec(formatter_cfg, formatters_registry)
            logger.debug("Using single formatter for all symbols")
            return SingleFormatter:new(formatter)

        -- Case 2: Config table with explicit type
        elseif type(formatter_cfg) == "table" and formatter_cfg.type then
            local cfg_type = formatter_cfg.type

            if cfg_type == "single" then
                -- Single formatter
                local formatter = resolve_formatter_spec(formatter_cfg.formatter or "refs_most_left", formatters_registry)
                logger.debug("Using single formatter (explicit): %s", formatter_cfg.formatter or "refs_most_left")
                return SingleFormatter:new(formatter)

            elseif cfg_type == "first_and_following" then
                -- First and following formatters (current default behavior)
                local first = resolve_formatter_spec(formatter_cfg.first or "refs_most_left", formatters_registry)
                local following = resolve_formatter_spec(formatter_cfg.following or "refs_most_left", formatters_registry)
                logger.debug("Using first_and_following formatter")
                return FirstAndOthersFormatter:new(first, following)

            elseif cfg_type == "position" then
                -- Position-based array
                local position_formatters = {}
                local default = resolve_formatter_spec(formatter_cfg.default or "refs_most_left", formatters_registry)

                -- Resolve numeric position entries
                for k, v in pairs(formatter_cfg) do
                    if type(k) == "number" then
                        position_formatters[k] = resolve_formatter_spec(v, formatters_registry)
                    end
                end

                logger.debug("Using position-based formatter with %d positions", vim.tbl_count(position_formatters))
                return PositionFormatter:new(position_formatters, default)

            elseif cfg_type == "selector" then
                -- Custom selector function
                if type(formatter_cfg.selector) == "function" then
                    logger.debug("Using custom selector formatter")
                    return SelectorFormatter:new(formatter_cfg.selector, formatters_registry)
                else
                    logger.warn("selector type specified but no selector function provided, falling back to default")
                    local default_formatter = resolve_formatter_spec("refs_most_left", formatters_registry)
                    return SingleFormatter:new(default_formatter)
                end

            else
                logger.warn("Unknown formatter type '%s', falling back to default", cfg_type)
                local default_formatter = resolve_formatter_spec("refs_most_left", formatters_registry)
                return SingleFormatter:new(default_formatter)
            end

        else
            logger.warn("Invalid formatter config, falling back to default")
            local default_formatter = resolve_formatter_spec("refs_most_left", formatters_registry)
            return SingleFormatter:new(default_formatter)
        end

    elseif opts.align_first or opts.align_following then
        -- Backward compatibility: old align_first/align_following config
        logger.warn("align_first/align_following are deprecated. Use formatter = {type='first_and_following', first=..., following=...}")

        local first = resolve_formatter_spec(opts.align_first or "refs_most_left", formatters_registry)
        local following = resolve_formatter_spec(opts.align_following or "refs_most_left", formatters_registry)
        return FirstAndOthersFormatter:new(first, following)

    else
        -- No formatter config: default to single formatter
        logger.debug("No formatter config, using default single formatter")
        local default_formatter = resolve_formatter_spec("refs_most_left", formatters_registry)
        return SingleFormatter:new(default_formatter)
    end
end

return M
