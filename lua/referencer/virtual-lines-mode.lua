local M = {}

local config = require("referencer.config")
local utils = require("referencer.utils")
-- Track virtual line state per line: { [bufnr] = { [line] = { symbols = { {col, symbol_data, symbol_start_col, symbol_end_col}, ... }, mark_id = ... } } }
local virtual_line_state = {}

-- Track mark state for virtual line mode: { [bufnr] = { ["line:col"] = { text = "...", line = ..., col = ..., symbol_data = ... } } }
local mark_state = {}
local first_symbol_drawer = nil
local following_symbol_drawer = nil

-- Built-in alignment functions for virtual lines
M.aligners = {}

function M.aligners.most_left(symbol_data, start_col, end_col, symbol_start_col, symbol_end_col)
    local refs_count = #symbol_data.references - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    -- start_col is already set correctly by the caller:
    -- - for first symbol: line's first non-whitespace column
    -- - for following symbols: end_col of previous symbol + 1
    return { text = text, col = start_col }
end

function M.aligners.left(symbol_data, start_col, end_col, symbol_start_col, symbol_end_col)
    local refs_count = #symbol_data.references - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    return { text = text, col = symbol_start_col }
end

function M.aligners.center(symbol_data, start_col, end_col, symbol_start_col, symbol_end_col)
    local refs_count = #symbol_data.references - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    local symbol_width = symbol_end_col - symbol_start_col
    local text_width = #text
    local center_offset = math.floor((symbol_width - text_width) / 2)
    local col = math.max(start_col, symbol_start_col + center_offset)
    return { text = text, col = col }
end

function M.aligners.right(symbol_data, start_col, end_col, symbol_start_col, symbol_end_col)
    local refs_count = #symbol_data.references - 1
    local text = string.format(config.options.format or "→ %d", refs_count)
    local text_width = #text
    local col = math.max(start_col, symbol_end_col - text_width)
    return { text = text, col = col }
end

local function update_virtual_line_for_line(bufnr, line, ns)
    -- This function creates a virtual line with text positioned at specific buffer columns
    if not virtual_line_state[bufnr] then
        virtual_line_state[bufnr] = {}
    end

    local line_state = virtual_line_state[bufnr][line]
    if not line_state or not line_state.symbols or #line_state.symbols == 0 then
        -- No symbols, remove virtual line if it exists
        if line_state and line_state.mark_id then
            pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, line_state.mark_id)
        end
        virtual_line_state[bufnr][line] = nil
        return
    end

    -- Sort symbols by column
    table.sort(line_state.symbols, function(a, b) return a.col < b.col end)

    -- Get drawer functions



    local virt_line_pos = config.options.display_mode or "above"

    -- Get line text for calculating positions
    local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
    local indent = line_text:match("^%s*") or ""
    local line_start_col = #indent

    -- Get horizontal scroll offset to make virtual lines scroll with text
    local leftcol = 0
    -- Find the window displaying this buffer
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            leftcol = vim.fn.getwininfo(win)[1].leftcol
            break
        end
    end

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

    -- Delete old mark if exists
    if line_state.mark_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, line_state.mark_id)
    end

    local last_symbol_end_col = 0  -- Track where the last symbol ended in the buffer
    local virt_text_chunks = {}
    local current_col = 0  -- Track our position in building the virtual line

    -- Build virtual line with text at specific columns
    for i, symbol_info in ipairs(line_state.symbols) do
        local symbol_col = symbol_info.col
        local symbol_data = symbol_info.symbol_data
        local symbol_start_col = symbol_info.symbol_start_col
        local symbol_end_col = symbol_info.symbol_end_col

        -- Calculate available space for this symbol
        local start_col
        if i == 1 then
            start_col = line_start_col  -- First symbol: start at first non-whitespace
        else
            -- Following symbols: find first non-whitespace after previous symbol ended
            local calculated_start = find_next_nonwhitespace(line_text, last_symbol_end_col)
            -- However, if the actual symbol starts BEFORE our calculated position
            -- (can happen when LSP gives qualified names like "M.aligners.func" but only "func" is in buffer),
            -- use the actual symbol position instead
            start_col = math.min(calculated_start, symbol_start_col)
        end

        local end_col
        if i < #line_state.symbols then
            end_col = line_state.symbols[i + 1].symbol_start_col
        else
            -- Last symbol: give it space until reasonable line width
            end_col = math.max(symbol_end_col + 20, 120)
        end

        -- Call appropriate drawer
        local drawer = i == 1 and first_symbol_drawer or following_symbol_drawer
        local result = drawer(symbol_data, start_col, end_col, symbol_start_col, symbol_end_col)

        if result and result.text and result.text ~= "" then
            local target_col = result.col

            -- Adjust target_col for horizontal scroll
            local adjusted_col = target_col - leftcol

            -- Only render text if it's visible (not scrolled off left edge)
            if adjusted_col >= 0 then
                -- Add spacing from current position to adjusted target position
                local spacing = math.max(0, adjusted_col - current_col)
                if spacing > 0 then
                    table.insert(virt_text_chunks, { string.rep(" ", spacing), "Normal" })
                    current_col = current_col + spacing
                end

                -- Add the symbol text
                table.insert(virt_text_chunks, { result.text, config.get_hl_group() })
                current_col = current_col + #result.text
            end
            -- If mark is off-screen (adjusted_col < 0), we simply don't render it
            -- But the virtual line is still created (if any marks are visible)
            -- This prevents the line from collapsing

            -- Update where this symbol ended in the buffer (not in virtual line!)
            last_symbol_end_col = symbol_end_col
        end
    end

    -- Create virtual line - always create it to prevent lines from disappearing
    -- Even if all marks are off-screen, we want the line to exist
    if #line_state.symbols > 0 then
        -- If we have no visible content, add at least one space to keep the line alive
        if #virt_text_chunks == 0 then
            table.insert(virt_text_chunks, { " ", "Normal" })
        end

        local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
            virt_lines = { virt_text_chunks },
            virt_lines_above = virt_line_pos == "above",
            hl_mode = "combine",
        })

        if ok then
            virtual_line_state[bufnr][line].mark_id = mark_id
        end
    end
end

function M.set_virtual_text(bufnr, line, col, text_to_add, symbol_data, ns)

    -- Initialize buffer state if needed
    if not mark_state[bufnr] then
        mark_state[bufnr] = {}
    end

    local key = utils.make_mark_key(line, col)

    -- Check if we already have this exact mark
    local current = mark_state[bufnr][key]
    if current and current.text == text_to_add then
        return  -- No change needed
    end

    local use_same_line = config.options.virtual_line_same_line

    -- Default to same line positioning
    if use_same_line == nil then
        use_same_line = true
    end

    if use_same_line then
        -- Show as end-of-line virtual text on the same line as the symbol
        -- Delete old mark if it exists
        if current and current.mark_id then
            pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, current.mark_id)
        end

        local virt_texts = {{ text_to_add, config.get_hl_group() }}

        local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
            virt_text = virt_texts,
            virt_text_pos = "eol",
            hl_mode = "combine",
        })

        if ok then
            mark_state[bufnr][key] = {
                text = text_to_add,
                mark_id = mark_id,
                line = line,
                col = col,
                symbol_data = symbol_data
            }
        end
    else
        -- Use combined virtual line approach with drawer callbacks
        -- Update the symbol in virtual_line_state
        if not virtual_line_state[bufnr] then
            virtual_line_state[bufnr] = {}
        end
        if not virtual_line_state[bufnr][line] then
            virtual_line_state[bufnr][line] = { symbols = {} }
        end

        -- Calculate symbol end column
        -- Note: LSP might give us qualified names like "M.aligners.func" 
        -- but only "func" appears in the buffer at the position
        -- So we need to extract the actual text from the buffer
        local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        local symbol_name = symbol_data.symbol.name or ""
        local symbol_start_col = col

        -- Extract actual text at the position to get real length
        -- Look for word boundaries (space, punctuation, etc.)
        local after_col = line_text:sub(col + 1)  -- +1 for Lua indexing
        local actual_symbol = after_col:match("^([%w_]+)")
        local actual_length = actual_symbol and #actual_symbol or #symbol_name

        local symbol_end_col = col + actual_length

        -- Find and update or add this symbol
        local found = false
        for i, sym in ipairs(virtual_line_state[bufnr][line].symbols) do
            if sym.col == col then
                sym.symbol_data = symbol_data
                sym.symbol_start_col = symbol_start_col
                sym.symbol_end_col = symbol_end_col
                found = true
                break
            end
        end

        if not found then
            table.insert(virtual_line_state[bufnr][line].symbols, {
                col = col,
                symbol_data = symbol_data,
                symbol_start_col = symbol_start_col,
                symbol_end_col = symbol_end_col
            })
        end

        -- Update mark state
        mark_state[bufnr][key] = {
            text = text_to_add,
            mark_id = nil,  -- Virtual line marks are tracked separately
            line = line,
            col = col,
            symbol_data = symbol_data
        }

        -- Rebuild the combined virtual line for this line
        update_virtual_line_for_line(bufnr, line, ns)
    end
end

function M.remove_virtual_text(bufnr, line, col, ns)

    if not mark_state[bufnr] then
        return
    end

    local key = utils.make_mark_key(line, col)
    local current = mark_state[bufnr][key]

    if not current then
        return
    end

    local use_same_line = config.options.virtual_line_same_line
    if use_same_line == nil then
        use_same_line = true
    end

    if not use_same_line then
        -- Remove from virtual_line_state
        if virtual_line_state[bufnr] and virtual_line_state[bufnr][line] then
            local symbols = virtual_line_state[bufnr][line].symbols
            for i, sym in ipairs(symbols) do
                if sym.col == col then
                    table.remove(symbols, i)
                    break
                end
            end
            -- Rebuild the virtual line
            update_virtual_line_for_line(bufnr, line, ns)
        end
    else
        -- Normal mark deletion
        if current.mark_id then
            pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, current.mark_id)
        end
    end

    mark_state[bufnr][key] = nil
end

function M.clear_buffer(bufnr, ns)
    -- Clear our tracking state
    if mark_state[bufnr] then
        mark_state[bufnr] = nil
    end

    if virtual_line_state[bufnr] then
        virtual_line_state[bufnr] = nil
    end

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

function M.update_on_scroll(bufnr, ns)
    -- Update virtual lines on horizontal scroll
    if virtual_line_state[bufnr] then
        -- Rebuild all virtual lines with new scroll offset
        for line, _ in pairs(virtual_line_state[bufnr]) do
            update_virtual_line_for_line(bufnr, line, ns)
        end
    end
end

function M.init(opts, ns)
    -- Helper function to resolve alignment option to drawer function
    local function resolve_drawer(drawer_option)
        -- If custom drawer function is provided, use it
        if type(drawer_option) == "function" then
            return drawer_option
        end

        -- Otherwise, map alignment string to built-in aligner
        if type(drawer_option) == "string" then
            local aligner = M.aligners[drawer_option]
            if not aligner then
                -- Warn about invalid alignment, fallback to default
                vim.notify(
                    string.format("Invalid text_align '%s', using 'most_left'", drawer_option),
                    vim.log.levels.WARN
                )
                return M.aligners.most_left
            end
            return aligner
        end

        -- Handle nil or invalid types - use default
        if drawer_option ~= nil then
            vim.notify(
                string.format("Invalid text_align type '%s', expected string or function", type(drawer_option)),
                vim.log.levels.WARN
            )
        end

        return M.aligners.most_left
    end

    first_symbol_drawer = resolve_drawer(opts.mode.align_first)
    following_symbol_drawer = resolve_drawer(opts.mode.align_following)
end

return M
