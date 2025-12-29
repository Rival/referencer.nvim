local config = require("referencer.config")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local Animations = require("referencer.animations")

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

---Calculate total display width of chunks
---@param chunks table Array of {text, hl} tuples
---@return integer total_width Total display width
local function calculate_width(chunks)
    local width = 0
    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end
    return width
end

-- ============================================================================
-- ALIGNMENT FUNCTIONS
-- ============================================================================

local aligners = {}

---Align reference count to leftmost position (span start)
---Shows "?" during validation, then formatted reference count
---@type GetVirtualTextBySymbol
function aligners.most_left(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    if SymbolInfo.get_validated_tick(symbol_info) == 0 then
        local chunks = {{"?", "Comment"}}
        return chunks, span_col, calculate_width(chunks)
    end
    local text = string.format(config.options.format or "→ %d", refs_count)
    local chunks = {{text, "Comment"}}
    return chunks, span_col, calculate_width(chunks)
end

---Align reference count to symbol start (left edge of symbol)
---@type GetVirtualTextBySymbol
function aligners.left(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    local chunks = {{text, "Comment"}}
    return chunks, symbol_col, calculate_width(chunks)
end

---Center reference count within symbol width
---@type GetVirtualTextBySymbol
function aligners.center(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    local chunks = {{text, "Comment"}}
    local text_width = calculate_width(chunks)
    local symbol_width = symbol_end_col - symbol_col
    local center_offset = math.floor((symbol_width - text_width) / 2)
    local col = math.max(span_col, symbol_col + center_offset)
    return chunks, col, text_width
end

---Align reference count to symbol end (right edge of symbol)
---@type GetVirtualTextBySymbol
function aligners.right(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
    local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    local chunks = {{text, "Comment"}}
    local text_width = calculate_width(chunks)
    local col = math.max(span_col, symbol_end_col - text_width)
    return chunks, col, text_width
end

-- ============================================================================
-- ANIMATION HELPERS
-- ============================================================================

---Replace text with spinner animation during waiting state
---@param base_formatter GetVirtualTextBySymbol The alignment formatter to wrap
---@param spinner_frames table[] Spinner frames
---@return GetVirtualTextBySymbolAnimated
local function waiting_with_spinner(base_formatter, spinner_frames)
    return function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol, adorner_data, time)
        local base_chunks, target_col, base_width = base_formatter(adorner, line, span_col, span_end_col,
                                           symbol_col, symbol_end_col, symbol)
        if not base_chunks then return nil end

        -- Use base_width from formatter (no recalculation needed!)
        local frame_idx = math.floor(time / 100) % #spinner_frames + 1
        local spinner_char = spinner_frames[frame_idx][1]
        local spinner_width = vim.fn.strdisplaywidth(spinner_char)
        local padding = string.rep(" ", math.max(0, base_width - spinner_width))

        return {{spinner_char .. padding, "Special"}}, target_col, base_width
    end
end

---Cycle highlight colors - now with multi-segment support
---@param base_formatter GetVirtualTextBySymbol The alignment formatter to wrap
---@param highlight_frames table[] Highlight group frames
---@return GetVirtualTextBySymbolAnimated
local function color_cycle(base_formatter, highlight_frames)
    return function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol, adorner_data, time)
        local chunks, col, width = base_formatter(adorner, line, span_col, span_end_col,
                                        symbol_col, symbol_end_col, symbol)
        if not chunks then return nil, col, 0 end

        local frame_idx = math.floor(time / 150) % #highlight_frames + 1
        local hl_group = highlight_frames[frame_idx]

        -- Apply cycled highlight to all chunks
        local colored_chunks = {}
        for i, chunk in ipairs(chunks) do
            colored_chunks[i] = {chunk[1], hl_group}
        end

        return colored_chunks, col, width
    end
end

-- ============================================================================
-- FORMATTERS FACTORY
-- ============================================================================

---Create all formatter presets
---@param VirtualLineFormatter table The VirtualLineFormatter class
---@return table<string, VirtualLineFormatter> Table of formatter presets
local function create_formatters(VirtualLineFormatter)
    local formatters = {}

    -- Alignment variants (static, no animation)
    formatters.refs_most_left = VirtualLineFormatter:new({
        text = aligners.most_left,
    })

    formatters.refs_left = VirtualLineFormatter:new({
        text = aligners.left,
    })

    formatters.refs_center = VirtualLineFormatter:new({
        text = aligners.center,
    })

    formatters.refs_right = VirtualLineFormatter:new({
        text = aligners.right,
    })

    -- Alignment variants with spinner animation during validation
    formatters.refs_most_left_spinner = VirtualLineFormatter:new({
        text = aligners.most_left,
        waiting_animated = waiting_with_spinner(
            aligners.most_left,
            Animations.animations.spinner_braille
        ),
    })

    formatters.refs_left_spinner = VirtualLineFormatter:new({
        text = aligners.left,
        waiting_animated = waiting_with_spinner(
            aligners.left,
            Animations.animations.spinner_braille
        ),
    })

    formatters.refs_center_spinner = VirtualLineFormatter:new({
        text = aligners.center,
        waiting_animated = waiting_with_spinner(
            aligners.center,
            Animations.animations.spinner_braille
        ),
    })

    formatters.refs_right_spinner = VirtualLineFormatter:new({
        text = aligners.right,
        waiting_animated = waiting_with_spinner(
            aligners.right,
            Animations.animations.spinner_braille
        ),
    })

    formatters.test_mark_id_left_spinner = VirtualLineFormatter:new({
        -- Animated version: show spinner with mark_id even in normal state
        text_animated = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info, adorner_data, time)
            local mark_id = tostring(SymbolInfo.get_mark_id(symbol_info))
            local frame_idx = math.floor(time / 100) % #Animations.animations.spinner_braille + 1
            local spinner_char = Animations.animations.spinner_braille[frame_idx][1]
            local text = string.format("%s %s", spinner_char, mark_id)
            local chunks = {{text, "Special"}}
            return chunks, symbol_col, calculate_width(chunks)
        end,
        -- Static fallback (used when animations disabled globally)
        text = function (adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local mark_id = tostring(SymbolInfo.get_mark_id(symbol_info))
            local text = string.format(config.options.format or "→ %d", mark_id)
            local chunks = {{text, "Comment"}}
            return chunks, symbol_col, calculate_width(chunks)
        end,
        -- Waiting state animation (used when LSP hasn't responded yet)
        waiting_animated = waiting_with_spinner(
            aligners.left,
            Animations.animations.spinner_braille
        ),
    })

    -- Multi-segment formatter: Color-coded by reference count
    -- Demonstrates multi-segment styling with different colors for arrow, count, and label
    formatters.refs_most_left_multicolor = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1

            -- Choose highlight for count based on usage
            local count_hl
            if refs_count == 0 then
                count_hl = "Comment"       -- Gray for unused
            elseif refs_count < 5 then
                count_hl = "String"        -- Green for low usage
            else
                count_hl = "WarningMsg"    -- Yellow for high usage
            end

            local chunks = {
                {"→ ", "Comment"},                   -- Arrow in gray
                {tostring(refs_count), count_hl},    -- Count in dynamic color
                {" refs", "Comment"}                 -- Label in gray
            }
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Highlight first symbol differently
    -- Demonstrates per-symbol styling based on symbol index
    formatters.refs_highlight_first = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info, adorner_data)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local text = string.format("→ %d", refs_count)
            local index = SymbolInfo.get_index(symbol_info)

            -- First symbol gets special highlight
            local hl = index == 1 and "Title" or "Comment"

            local chunks = {{text, hl}}
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- EXAMPLE: Smart caching formatter that reuses chunks when ref count unchanged
    -- Demonstrates the reference equality optimization pattern
    formatters.refs_most_left_cached = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info, adorner_data)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1

            -- Check if we can reuse cached chunks
            if adorner_data.text_chunks and adorner_data.cached_refs_count == refs_count then
                -- Return cached chunks directly (reference equality signals reuse)
                return adorner_data.text_chunks, span_col, adorner_data.width_cache
            end

            -- Ref count changed - rebuild chunks
            local text = string.format(config.options.format or "→ %d", refs_count)
            local chunks = {{text, "Comment"}}

            -- Cache the ref count for next comparison
            adorner_data.cached_refs_count = refs_count

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- EXAMPLE: Conditional formatter that only updates on specific events
    -- Demonstrates selective recalculation based on symbol state
    formatters.refs_smart_update = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info, adorner_data)
            local symbol_data = SymbolInfo.get_symbol_data(symbol_info)
            local refs_count = #symbol_data.refs - 1
            local validated_tick = SymbolInfo.get_validated_tick(symbol_info)

            -- Check if anything changed since last render
            if adorner_data.text_chunks
               and adorner_data.last_refs_count == refs_count
               and adorner_data.last_validated_tick == validated_tick then
                -- Nothing changed - reuse cached chunks
                return adorner_data.text_chunks, span_col, adorner_data.width_cache
            end

            -- Something changed - recalculate
            local chunks
            if validated_tick == 0 then
                chunks = {{"?", "Comment"}}
            else
                local text = string.format("→ %d", refs_count)
                chunks = {{text, "Comment"}}
            end

            -- Update cache state
            adorner_data.last_refs_count = refs_count
            adorner_data.last_validated_tick = validated_tick

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- ========================================================================
    -- SYMBOL-USAGE.NVIM STYLE FORMATTERS
    -- ========================================================================
    -- Formatters inspired by symbol-usage.nvim's default text_format
    -- Shows usage count with proper grammar (e.g., "no usage", "1 usage", "5 usages")

    -- Simple usage-based formatter (mimics symbol-usage.nvim default)
    formatters.usage_text = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local text = string.format("%s %s", num_text, usage_label)
            local chunks = {{text, "Comment"}}
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Usage text with multi-colored segments (number highlighted differently)
    formatters.usage_text_colored = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'

            -- Choose color based on usage count
            local num_hl = refs_count == 0 and "Comment" or "Number"
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)

            local chunks = {
                {num_text, num_hl},
                {" " .. usage_label, "Comment"}
            }
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Compact refs count (symbol-usage.nvim style, aligned to symbol)
    formatters.usage_text_left = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local text = string.format("%s %s", num_text, usage_label)
            local chunks = {{text, "Comment"}}
            return chunks, symbol_col, calculate_width(chunks)
        end,
    })

    -- Usage text with color coding by count (symbol-usage.nvim enhanced style)
    formatters.usage_text_semantic = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'

            -- Semantic highlighting based on usage
            local hl
            if refs_count == 0 then
                hl = "DiagnosticWarn"    -- Unused - warning yellow
            elseif refs_count < 3 then
                hl = "Comment"           -- Low usage - gray
            elseif refs_count < 10 then
                hl = "String"            -- Normal usage - green
            else
                hl = "Special"           -- High usage - cyan
            end

            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local text = string.format("%s %s", num_text, usage_label)
            local chunks = {{text, hl}}
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Full symbol-usage.nvim style: "X usages" with proper validation state
    formatters.usage_full = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local validated_tick = SymbolInfo.get_validated_tick(symbol_info)

            -- Show loading state while validating
            if validated_tick == 0 then
                local chunks = {{"loading...", "Comment"}}
                return chunks, span_col, calculate_width(chunks)
            end

            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local text = string.format("%s %s", num_text, usage_label)
            local chunks = {{text, "Comment"}}
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- symbol-usage.nvim default style with spinner animation
    formatters.usage_full_spinner = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local text = string.format("%s %s", num_text, usage_label)
            local chunks = {{text, "Comment"}}
            return chunks, span_col, calculate_width(chunks)
        end,
        waiting_animated = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol, adorner_data, time)
            local frame_idx = math.floor(time / 100) % #Animations.animations.spinner_braille + 1
            local spinner_char = Animations.animations.spinner_braille[frame_idx][1]
            local text = spinner_char .. " loading..."
            local chunks = {{text, "Special"}}
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Compact "Xref" / "Xrefs" style (very minimal)
    formatters.refs_compact = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local label = refs_count == 1 and 'ref' or 'refs'
            local text = string.format("%d%s", refs_count, label)
            local chunks = {{text, "Comment"}}
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Multi-segment with icons (modern style)
    formatters.usage_icons = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1

            -- Choose icon based on count
            local icon = refs_count == 0 and "󰀦" or "󰌹"  -- Nerd font icons
            local num_hl = refs_count == 0 and "DiagnosticWarn" or "Number"

            local chunks = {
                {icon .. " ", "Special"},
                {tostring(refs_count), num_hl},
                {" refs", "Comment"}
            }
            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- ========================================================================
    -- ROUNDED PILL STYLE (symbol-usage.nvim advanced example)
    -- ========================================================================
    -- Beautiful rounded badge/pill style with icons and custom backgrounds
    -- Requires Nerd Fonts and creates custom highlight groups

    -- Helper to setup custom highlight groups (call once during init)
    local function setup_pill_highlights()
        local function h(name)
            return vim.api.nvim_get_hl(0, { name = name })
        end

        -- Rounded corners with CursorLine background
        vim.api.nvim_set_hl(0, 'ReferencerPillRounding', {
            fg = h('CursorLine').bg,
            italic = true
        })

        -- Content background matching CursorLine
        vim.api.nvim_set_hl(0, 'ReferencerPillContent', {
            bg = h('CursorLine').bg,
            fg = h('Comment').fg,
            italic = true
        })

        -- Reference icon/count highlighting
        vim.api.nvim_set_hl(0, 'ReferencerPillRef', {
            fg = h('Function').fg,
            bg = h('CursorLine').bg,
            italic = true
        })

        -- Unused/warning highlighting
        vim.api.nvim_set_hl(0, 'ReferencerPillWarn', {
            fg = h('DiagnosticWarn').fg,
            bg = h('CursorLine').bg,
            italic = true
        })
    end

    -- Call setup once (idempotent)
    setup_pill_highlights()

    -- Rounded pill formatter (symbol-usage.nvim style)
    -- Uses Powerline Extra glyphs: U+E0B6 (left) and U+E0B4 (right)
    -- These are the EXACT same glyphs as symbol-usage.nvim's round_start/round_end
    formatters.usage_pill = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)

            -- Choose colors based on usage
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            -- Exact characters from symbol-usage.nvim example
            local round_start = ''  -- U+E0B6 - Powerline left rounded
            local round_end = ''    -- U+E0B4 - Powerline right rounded

            local chunks = {
                {round_start, 'ReferencerPillRounding'},            -- Left rounded corner
                {'󰌹 ', icon_hl},                                     -- Icon
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'}, -- Text
                {round_end, 'ReferencerPillRounding'},              -- Right rounded corner
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Rounded pill with multiple segments (references + stacked count)
    formatters.usage_pill_full = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)

            -- Choose colors based on usage
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'', 'ReferencerPillRounding'},                      -- Left rounded
                {'󰌹 ', icon_hl},                                     -- Icon
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'}, -- Text
                {'', 'ReferencerPillRounding'},                      -- Right rounded
            }

            -- Add stacked count indicator if there are other symbols on same line
            -- (This would require line_info context -示例仅显示结构)
            local index = SymbolInfo.get_index(symbol_info)
            if index and index > 1 then
                -- Add spacing
                table.insert(chunks, {' ', 'NonText'})
                -- Add stacked indicator pill
                table.insert(chunks, {'', 'ReferencerPillRounding'})
                table.insert(chunks, {' ', 'ReferencerPillContent'})
                table.insert(chunks, {'+' .. (index - 1), 'ReferencerPillContent'})
                table.insert(chunks, {'', 'ReferencerPillRounding'})
            end

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Compact pill style (minimal version)
    formatters.usage_pill_compact = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'', 'ReferencerPillRounding'},
                {'󰌹 ', icon_hl},
                {tostring(refs_count), 'ReferencerPillContent'},
                {'', 'ReferencerPillRounding'},
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Pill style with animated spinner during validation
    formatters.usage_pill_spinner = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'', 'ReferencerPillRounding'},
                {'󰌹 ', icon_hl},
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'},
                {'', 'ReferencerPillRounding'},
            }

            return chunks, span_col, calculate_width(chunks)
        end,
        waiting_animated = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol, adorner_data, time)
            local frame_idx = math.floor(time / 100) % #Animations.animations.spinner_braille + 1
            local spinner_char = Animations.animations.spinner_braille[frame_idx][1]

            local chunks = {
                {'', 'ReferencerPillRounding'},
                {spinner_char .. ' ', 'ReferencerPillRef'},
                {'loading...', 'ReferencerPillContent'},
                {'', 'ReferencerPillRounding'},
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- ========================================================================
    -- ALTERNATIVE PILL STYLES (for fonts without powerline glyphs)
    -- ========================================================================

    -- Debug formatter to test glyph rendering
    formatters.debug_glyphs = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1

            -- Test various glyph options
            local chunks = {
                -- Powerline glyphs (original)
                {' LEFT', 'Comment'},
                {' RIGHT', 'Comment'},
                {' | ', 'NonText'},
                -- Alternative rounded corners
                {'( ', 'Comment'},
                {tostring(refs_count), 'Number'},
                {' )', 'Comment'},
                {' | ', 'NonText'},
                -- Box drawing
                {'[ ', 'Comment'},
                {tostring(refs_count), 'Number'},
                {' ]', 'Comment'},
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Pill with parentheses (works without Nerd Fonts)
    formatters.usage_pill_parens = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'( ', 'ReferencerPillRounding'},
                {'󰌹 ', icon_hl},
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'},
                {' )', 'ReferencerPillRounding'},
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Pill with box brackets (ASCII compatible)
    formatters.usage_pill_brackets = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'[ ', 'ReferencerPillRounding'},
                {'󰌹 ', icon_hl},
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'},
                {' ]', 'ReferencerPillRounding'},
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Pill with Unicode box drawing characters
    formatters.usage_pill_box = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'╭', 'ReferencerPillRounding'},  -- Box drawing: top-left
                {' ', 'ReferencerPillContent'},
                {'󰌹 ', icon_hl},
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'},
                {' ', 'ReferencerPillContent'},
                {'╮', 'ReferencerPillRounding'},  -- Box drawing: top-right
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    -- Pill with alternative powerline glyphs (thinner)
    formatters.usage_pill_alt = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'', 'ReferencerPillRounding'},  -- Alternative left (E0B2)
                {' ', 'ReferencerPillContent'},
                {'󰌹 ', icon_hl},
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'},
                {' ', 'ReferencerPillContent'},
                {'', 'ReferencerPillRounding'},  -- Alternative right (E0B0)
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })

    formatters.usage_labels_alt = VirtualLineFormatter:new({
        text = function(adorner, line, span_col, span_end_col, symbol_col, symbol_end_col, symbol_info)
            local refs_count = #SymbolInfo.get_symbol_data(symbol_info).refs - 1
            local usage_label = refs_count <= 1 and 'usage' or 'usages'
            local num_text = refs_count == 0 and 'no' or tostring(refs_count)
            local icon_hl = refs_count == 0 and 'ReferencerPillWarn' or 'ReferencerPillRef'

            local chunks = {
                {'󰍞', 'ReferencerPillRounding'},  -- Alternative left (E0B2)
                {' ', 'ReferencerPillContent'},
                {'󰌹 ', icon_hl},
                {('%s %s'):format(num_text, usage_label), 'ReferencerPillContent'},
                {' ', 'ReferencerPillContent'},
                {'󰍟', 'ReferencerPillRounding'},  -- Alternative right (E0B0)
            }

            return chunks, span_col, calculate_width(chunks)
        end,
    })
    return formatters
end

return create_formatters
