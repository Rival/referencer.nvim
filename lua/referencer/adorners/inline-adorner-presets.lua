local config = require("referencer.config")
local utils = require("referencer.utils")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local Animations = require("referencer.animations")

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

local function if_refs_changed(mark, adorner_data)
    local old_refs = adorner_data.refs
    if not old_refs then
        old_refs = - 2
    end
    local refs = #SymbolInfo.get_symbol_data(mark).refs - 1
    adorner_data.refs = refs
    return old_refs ~= refs, refs
end

-- ============================================================================
-- BASIC FORMATTER FUNCTIONS
-- ============================================================================

---@diagnostic disable-next-line: unused-local
local refs_formatter = function(adorner, _line, _col, mark, adorner_data)
    local yes, refs = if_refs_changed(mark, adorner_data)
    local new_line = nil
    if yes then
        new_line = {{string.format(config.options.format, refs), adorner.hl_group}}
    end
    return new_line, 0
end

-- Formatter that ALWAYS returns current refs (doesn't check for changes)
-- Used by waiting_with_spinner to ensure spinner is always shown
---@diagnostic disable-next-line: unused-local
local refs_formatter_always = function(adorner, _line, _col, mark, adorner_data)
    local refs = #SymbolInfo.get_symbol_data(mark).refs - 1
    adorner_data.refs = refs  -- Keep adorner_data in sync
    return {{string.format(config.options.format, refs), adorner.hl_group}}, 0
end

---@diagnostic disable-next-line: unused-local
local refs_superscript_formatter = function(adorner, _line, _col, mark, adorner_data)
    local yes, refs = if_refs_changed(mark, adorner_data)
    local new_line = nil
    if yes then
        new_line = {{string.format(config.options.format, utils.get_number_superscript(refs)), adorner.hl_group}}
    end
    return new_line, 0
end

-- Always-show version for waiting animations
---@diagnostic disable-next-line: unused-local
local refs_superscript_formatter_always = function(adorner, _line, _col, mark, adorner_data)
    local refs = #SymbolInfo.get_symbol_data(mark).refs - 1
    adorner_data.refs = refs
    return {{string.format(config.options.format, utils.get_number_superscript(refs)), adorner.hl_group}}, 0
end

---@diagnostic disable-next-line: unused-local
local refs_subscript_formatter = function(adorner, _line, _col, mark, adorner_data)
    local yes, refs = if_refs_changed(mark, adorner_data)
    local new_line = nil
    if yes then
        new_line = {{string.format(config.options.format, utils.get_number_subscript(refs)), adorner.hl_group}}
    end
    return new_line, 0
end

-- Always-show version for waiting animations
---@diagnostic disable-next-line: unused-local
local refs_subscript_formatter_always = function(adorner, _line, _col, mark, adorner_data)
    local refs = #SymbolInfo.get_symbol_data(mark).refs - 1
    adorner_data.refs = refs
    return {{string.format(config.options.format, utils.get_number_subscript(refs)), adorner.hl_group}}, 0
end

-- ============================================================================
-- ANIMATION HELPERS
-- ============================================================================

local animations_helpers = {}

---Create a spinner animation that cycles through frames
---@param frames table[] Array of frames, each frame is {text, hl_group}
---@param interval number Milliseconds per frame
---@return GetVirtTextAnimated
function animations_helpers.spinner(frames, interval)
    interval = interval or 100
    return function(_adorner, _line, _col, _symbol, _adorner_data, time)
        local frame_idx = math.floor(time / interval) % #frames + 1
        return {frames[frame_idx]}, 0
    end
end

---Create animated waiting indicator (spinner replaces first char, rest becomes spaces)
---@param base_formatter GetVirtText The text formatter to wrap
---@param spinner_frames table[] Spinner frames
---@return GetVirtTextAnimated
function animations_helpers.waiting_with_spinner(base_formatter, spinner_frames)
    return function(adorner, line, col, symbol, adorner_data, time)
        -- Get base text
        local base_text = base_formatter(adorner, line, col, symbol, adorner_data)
        if not base_text then return nil end

        -- Calculate total display width of base text
        local total_width = 0
        for _, part in ipairs(base_text) do
            total_width = total_width + vim.fn.strdisplaywidth(part[1])
        end

        -- Get current spinner frame
        local frame_idx = math.floor(time / 100) % #spinner_frames + 1
        local spinner = spinner_frames[frame_idx]
        local spinner_width = vim.fn.strdisplaywidth(spinner[1])

        -- Spinner at position 1, rest padded with spaces to preserve total width
        local remaining_width = total_width - spinner_width
        local padding = string.rep(" ", math.max(0, remaining_width))

        return {{spinner[1] .. padding, spinner[2]}}, 0
    end
end

---Animate just the color/highlight group, keeping the same text
---@param base_formatter GetVirtText The text formatter to wrap
---@param highlight_groups string[] Array of highlight group names to cycle through
---@param interval number Milliseconds per color change
---@return GetVirtTextAnimated
function animations_helpers.color_cycle(base_formatter, highlight_groups, interval)
    interval = interval or 200
    return function(adorner, line, col, symbol, adorner_data, time)
        -- Get base text
        local base_text = base_formatter(adorner, line, col, symbol, adorner_data)
        if not base_text then return nil end

        -- Cycle through highlight groups
        local hl_idx = math.floor(time / interval) % #highlight_groups + 1
        local hl_group = highlight_groups[hl_idx]

        -- Apply pulsing highlight to all parts
        local result = {}
        for _, part in ipairs(base_text) do
            table.insert(result, {part[1], hl_group})
        end
        return result, 0
    end
end

-- ============================================================================
-- FORMATTERS FACTORY
-- ============================================================================

---Create all formatter presets
---@param InlineAdornerFormatter table The InlineAdornerFormatter class
---@return table<string, InlineAdornerFormatter> Table of formatter presets
local function create_formatters(InlineAdornerFormatter)
    local formatters = {}

    -- Basic formatters (no animation)
    formatters.refs = InlineAdornerFormatter:new({
        text = refs_formatter,
    })

    formatters.refs_superscript = InlineAdornerFormatter:new({
        text = refs_superscript_formatter,
    })

    formatters.refs_subscript = InlineAdornerFormatter:new({
        text = refs_subscript_formatter,
    })

    -- Formatters with waiting animation
    formatters.refs_waiting_animated = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.spinner_braille
        ),
    })

    formatters.refs_superscript_waiting_animated = InlineAdornerFormatter:new({
        text = refs_superscript_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_superscript_formatter_always,
            Animations.animations.spinner_braille
        ),
    })

    formatters.refs_subscript_waiting_animated = InlineAdornerFormatter:new({
        text = refs_subscript_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_subscript_formatter_always,
            Animations.animations.low_asterisk
        ),
    })

    -- Star-based waiting animations
    formatters.refs_waiting_stars_morph = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.stars_morph
        ),
    })

    formatters.refs_waiting_stars_sparkle = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.stars_sparkle
        ),
    })

    formatters.refs_waiting_star_pulse = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.star_pulse
        ),
    })

    formatters.refs_waiting_low_asterisk = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.low_asterisk
        ),
    })

    formatters.refs_waiting_star_operator = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.star_operator
        ),
    })

    formatters.refs_waiting_black_star = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.black_star
        ),
    })

    formatters.refs_waiting_white_star = InlineAdornerFormatter:new({
        text = refs_formatter,
        waiting_animated = animations_helpers.waiting_with_spinner(
            refs_formatter_always,
            Animations.animations.white_star
        ),
    })

    -- Test formatter: animates number sequences
    -- Normal state: cycles through big numbers 0-9
    -- Waiting state: cycles through subscript numbers 0-9
    formatters.test_all_animated = InlineAdornerFormatter:new({
        text = refs_superscript_formatter,
        text_animated = function(adorner, _line, _col, _symbol, _adorner_data, time)
            -- Cycle through big numbers 0-9
            local num = math.floor(time / 200) % 10
            return {{tostring(num), adorner.hl_group}}, 0
        end,
        waiting_animated = function(adorner, _line, _col, _symbol, _adorner_data, time)
            -- Cycle through subscript numbers 0-9
            local subscripts = {"₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉"}
            local idx = math.floor(time / 200) % 10 + 1
            return {{subscripts[idx], adorner.hl_group}}, 0
        end,
        should_animate = function(_symbol, _adorner_data)
            return true  -- Always animate for testing
        end,
    })

    return formatters
end

return create_formatters
