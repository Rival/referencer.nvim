local M = {}
local config = require("referencer.config")
local virtual_line_state = {}
local ns = 0

local hl_group = nil
-- local set_virtual_text_for_mode = nil
local text_formatter = nil
local virt_text_pos = nil
local set_virtual_text = nil

---@class MarkInfo
---@field old_line integer Line number before move (-1 if new mark)
---@field line integer Current line number (0-indexed)
---@field col integer Current column number (0-indexed)
---@field symbol_data table Symbol data with refs and other info
---@field text string Formatted text to display
---@field opts MarkOpts Extmark options
---@field updated? boolean Whether mark was updated in current cycle

---@class MarkOpts
---@field id? integer Extmark ID (set after creation)
---@field virt_text string[][] Array of [text, hl_group] pairs
---@field virt_text_pos string Position: "eol", "inline", etc.
---@field hl_mode string Highlight mode: "combine", "replace", etc.


-- Helper to create a unique key for a mark position
-- local function make_mark_key(line, col)
--     return line .. ":" .. col
-- end
-- local function make_mark_key(line, col)
--     return (line * 100000) + col  -- 100000 should be enough)
-- end



local function set_virtual_text_eol(ctx, bufnr, line, col, symbol_data)
    -- table.insert(ctx.calls, {line = line, col = col, refs = #symbol_data.refs - 1})
    local line_state = ctx.lines_states[line]
    if not line_state then
        line_state = { symbols = {} }
        ctx.lines_states[line] = line_state
    end
    local text_to_add = text_formatter(bufnr, line, col, symbol_data)

    --using in to update existing symbol
    local function update_mark(symbol_mark, text)
        -- if symbol_mark.updated then
        --     print(string.format("ERROR mark:%d {%d %d} text:%s kind %s call:{%d %d}  call_text %s call_kind %d",
        --         symbol_mark.opts.id, symbol_mark.line, symbol_mark.col, symbol_mark.text, symbol_mark.symbol_data.sym.kind, line, col, text, symbol_data.sym.kind))
        --     return -- No change
        -- end
        symbol_mark.symbol_data = symbol_data
        symbol_mark.updated = true
        if symbol_mark.text == text then
            -- print(string.format("{%d}%d:%d no change:", symbol_mark.opts.id, line, col))
            return -- No change
        end
        -- print(string.format("{%d}%d:%d changed to %s",symbol_mark.opts.id,line, col,text))
        -- Update extmark
        symbol_mark.opts.virt_text = {{ text, hl_group }}
        -- same position, but changed text
        local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, symbol_mark.line, symbol_mark.col, symbol_mark.opts)
        if ok then
            -- when set_extmark returns an id, update stored id and text
            if mark_id ~= symbol_mark.opts.id then
                print("Warning, in changed! old:" .. symbol_mark.opts.id .. "->" .. mark_id)
            end
            symbol_mark.text = text
        end
    end

    -- Find existing symbol at this column
    for _, symbol in ipairs(line_state.symbols) do
        if symbol.col == col and symbol.updated == false then
            -- print(string.format("exist text %s pos:%d:%d", text_to_add, line, col))
            update_mark(symbol, text_to_add)
            return
        end
    end

    --here defitely symbol was added, we will create them at the end trying to reuse existing unused
    local next_mark_infos = ctx.next_mark_infos or {}
    ctx.next_mark_infos = next_mark_infos
    table.insert(next_mark_infos, {
        old_line = -1,
        line = line,
        col = col,
        symbol_data = symbol_data,
        text = text_to_add,
        opts = {
            virt_text = {{ text_to_add, hl_group }},
            virt_text_pos = virt_text_pos,
            hl_mode = "combine",
        }
    })
    -- print(string.format("added info:%d:%d", line, col))
end

local function set_virtual_text_inline_after(ctx, bufnr, line, col, symbol_data)
    local symbol_end_col = col  -- Default to start

    -- print(vim.inspect(symbol_data))
    -- Get end column from symbol range
    if symbol_data.sym and symbol_data.sym.range then
        symbol_end_col = symbol_data.sym.selectionRange['end'].character
    end

    set_virtual_text_eol(ctx, bufnr, line, symbol_end_col, symbol_data)
end

function M.actualization_start(bufnr)
    local lines_state_buffer = virtual_line_state[bufnr] or {}
    virtual_line_state[bufnr] = lines_state_buffer

    -- local ext_marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {details = false})
    -- Build fast lookup table: mark_id -> {line, col}
    local mark_positions = {}
    local empy_param = {}
    for _, line_state in pairs(lines_state_buffer) do
        for i, symbol in ipairs(line_state.symbols) do
            -- Mark all symbols as not updated
            symbol.updated = false

            local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, symbol.opts.id, empy_param)
            if pos then
                symbol.col = pos[2]
                if pos[1] ~= symbol.line then
                    -- Mark has moved to other line
                    table.remove(line_state.symbols, i)
                    symbol.line = pos[1]
                    --create if needed, add and reset old_line
                    local new_line_state = lines_state_buffer[symbol.line]
                    if not new_line_state then
                        new_line_state = { symbols = {} }
                        lines_state_buffer[symbol.line] = new_line_state
                    end
                    table.insert(new_line_state.symbols, symbol)
                end
            end
        end
    end
    -- for _, mark_info in ipairs(ext_marks) do
    --     local id, line, col = mark_info[1], mark_info[2], mark_info[3]
    --     mark_positions[id] = {line = line, col = col}
    -- end
    -- -- Now check each symbol (fast O(1) lookup)
    -- for line, line_state in pairs(lines_state_buffer) do
    --     for i, symbol in ipairs(line_state.symbols) do
    --         -- Mark all symbols as not updated
    --         symbol.updated = false
    --
    --         -- Fast lookup instead of API call
    --         local pos = mark_positions[symbol.opts.id]
    --         if pos then
    --             symbol.col = pos.col
    --             if pos.line ~= symbol.line then
    --                 -- Mark has moved to other line
    --                 table.remove(line_state.symbols, i)
    --                 symbol.line = pos.line
    --                 --create if needed, add and reset old_line
    --                 local new_line_state = lines_state_buffer[symbol.line]
    --                 if not new_line_state then
    --                     new_line_state = { symbols = {} }
    --                     lines_state_buffer[symbol.line] = new_line_state
    --                 end
    --                 table.insert(new_line_state.symbols, symbol)
    --             end
    --         end
    --     end
    -- end

    --returns current buffer context to be passed to symbol invocations later
    return {
        bufnr = bufnr,
        lines_states = lines_state_buffer,
        -- markid_to_symbol = markid_to_symbol_buffer,
        -- calls = {}
    }
end

local function remove_empty_lines(ctx)
    -- Remove empty line_states
    for line, line_state in pairs(ctx.lines_states) do
        for i, symbol in ipairs(line_state.symbols) do
            --here we finally move mark symbol to other line_state
            if symbol.old_line > -1 then
                table.remove(line_state.symbols, i)
                --create if needed, add and reset old_line
                local new_line_state = ctx.lines_states[symbol.line]
                if not new_line_state then
                    new_line_state = { symbols = {} }
                    ctx.lines_states[symbol.line] = new_line_state
                end
                table.insert(new_line_state.symbols, symbol)
                symbol.old_line = -1
            end
        end
        --deleting empty lines
        if #line_state.symbols == 0 then
            ctx.lines_states[line] = nil
            -- print("deleting line" .. line)
        end
    end
end

function M.actualization_cancelled(ctx, bufnr)
    remove_empty_lines(ctx)
end

function M.actualization_end(ctx, bufnr)
    local delete_counter = 0
    local changed_counter = 0
    local created_counter = 0

    local next_marks_idx = 1

    local next_mark_infos = ctx.next_mark_infos
    -- Delete marks that no longer exist or changed
    for line, line_state in pairs(ctx.lines_states) do
        local i = 1
        while i <= #line_state.symbols do
            local symbol = line_state.symbols[i]
            if symbol.updated == false then
                local m_id = symbol.opts.id
                if next_mark_infos and next_marks_idx <= #next_mark_infos then
                    -- take existing and use
                    local new_mark_info = next_mark_infos[next_marks_idx]
                    symbol.opts = new_mark_info.opts
                    symbol.opts.id = m_id
                    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, new_mark_info.line, new_mark_info.col, symbol.opts)
                    if ok then
                        changed_counter = changed_counter + 1
                        next_marks_idx = next_marks_idx + 1
                        symbol.text = new_mark_info.text
                        symbol.col = new_mark_info.col
                        symbol.symbol_data = new_mark_info.symbol_data
                        if line ~= new_mark_info.line then
                            -- it is on other line than current
                            symbol.old_line = symbol.line
                            symbol.line = new_mark_info.line
                        end
                    end
                    i = i + 1
                else
                    -- Mark was removed - delete the old extmark
                    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, m_id)
                    delete_counter = delete_counter + 1
                    table.remove(line_state.symbols, i)
                    -- ctx.markid_to_symbol[m_id] = nil
                end
            else
                i = i + 1
            end
        end
    end

    -- Add new marks if they exist
    if next_mark_infos then
        while next_marks_idx <= #next_mark_infos do
            local mark = next_mark_infos[next_marks_idx]
            local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, mark.line, mark.col, mark.opts)
            created_counter = created_counter + 1
            if ok then
                mark.opts.id = mark_id
                local line_state = ctx.lines_states[mark.line]
                if not line_state then
                    line_state = { symbols = {} }
                    ctx.lines_states[mark.line] = line_state
                end
                table.insert(line_state.symbols, mark)
                -- ctx.markid_to_symbol[mark_id] = mark
            end
            next_marks_idx = next_marks_idx + 1
        end
    end

    remove_empty_lines(ctx)

    -- print(string.format(
    --     "[Marks] new_marks=%d | lines %d | created=%d | changed=%d | deleted=%d |\ncalls=%s",
    --     next_mark_infos and #next_mark_infos or 0, vim.tbl_count(ctx.lines_states), created_counter, changed_counter, delete_counter
    --     , vim.inspect(ctx.calls)
    -- ))

    -- next_mark_infos[bufnr] = nil
end




function M.actualization_discard(bufnr)
    M.clear_buffer(bufnr)
end

function M.set_virtual_text(ctx, bufnr, line, col, symbol_data)
    set_virtual_text(ctx, bufnr, line, col, symbol_data)
end

function M.remove_virtual_text(bufnr, line, col)
    -- This can be used to immediately remove a mark if needed
    -- if not markid_to_symbol[bufnr] then return end

end

function M.remove_all_marks_for_line(bufnr, line)
    -- if not markid_to_symbol[bufnr] then return end


end

function M.init_buffer(bufnr)
    -- markid_to_symbol[bufnr] = {}
end

function M.clear_buffer(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    -- markid_to_symbol[bufnr] = {}
end

function M.init(opts, namespace)
    ns = namespace
    hl_group = require("referencer.config").get_hl_group()
    virt_text_pos = opts.mode.virt_text_pos or "eol"

    -- If custom drawer function is provided, use it
    if type(opts.format) == "function" then
        text_formatter = opts.format
    else
        text_formatter = function (_,_,_,symbol_data)
            return string.format(config.options.format, #symbol_data.refs - 1) -- note, we take also our own ref so -1
        end
    end
    set_virtual_text = set_virtual_text_eol

    if opts.mode.align == "eol" or opts.mode.align == "right" then
        virt_text_pos = opts.mode.align
    else
        virt_text_pos = "inline"
        if opts.mode.align == "after" then
            set_virtual_text = set_virtual_text_inline_after
        end
    end
end

local function benchmark()
    local bufnr = vim.api.nvim_get_current_buf()
    local iterations = 1
    local lines_state_buffer = virtual_line_state[bufnr] or {}

    print("=== Realistic Benchmark (simulating actual code flow) ===")

    -- ✅ APPROACH 1: Individual calls during iteration
    local empy_param = {}
    local start1 = vim.uv.hrtime()
    for i = 1, iterations do
        local moved_count = 0
        for _, lines_state in pairs(lines_state_buffer) do
            for _, symbol in ipairs(lines_state.symbols) do
                local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, symbol.opts.id, empy_param)
                -- print(vim.inspect(pos))
                if pos and #pos >= 2 then
                    -- Simulate checking if moved
                    if pos[1] ~= symbol.line or pos[2] ~= symbol.col then
                        moved_count = moved_count + 1
                        symbol.line = pos[1]
                        symbol.col = pos[2]
                    end
                end
            end
        end
    end
    local time1 = (vim.uv.hrtime() - start1) / 1e6

    -- ✅ APPROACH 2: Batch call then lookup
    local start2 = vim.uv.hrtime()
    for i = 1, iterations do
        local ext_marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {details = false})
        local positions = {}
        for _, mark in ipairs(ext_marks) do
            positions[mark[1]] = {line = mark[2], col = mark[3]}
        end

        local moved_count = 0
        for _, lines_state in pairs(lines_state_buffer) do
            for _, symbol in ipairs(lines_state.symbols) do
                local pos = positions[symbol.opts.id]
                if pos then
                    -- Simulate checking if moved
                    if pos.line ~= symbol.line or pos.col ~= symbol.col then
                        moved_count = moved_count + 1
                        symbol.line = pos.line
                        symbol.col = pos.col
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

function M.print_all_symbols(bfrnr)
    local line_state_buffer = virtual_line_state[bfrnr]
    -- Find existing symbol at this column
    for line, line_state in pairs(line_state_buffer) do
        print("lines:" .. line)
        for _, symbol in ipairs(line_state.symbols) do
            print(string.format("symbol text: %s virt_text: %s", symbol.text, vim.inspect(symbol.opts and symbol.opts.virt_text)))
        end
    end
end

-- Run with: :lua require('your_module').benchmark_approach()
M.benchmark_approach = benchmark

return M
