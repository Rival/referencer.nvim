local M = {}

local flash_ns = vim.api.nvim_create_namespace("rainbow_flash")
local debug_ns = vim.api.nvim_create_namespace("debug_marks")
local current_index = 0
local debug_mode = false
local debug_marks = {}  -- Store active debug marks

local COLORS = {
    {name = "FlashRed",     bg = "#ff0000", fg = "#ffffff"},
    {name = "FlashOrange",  bg = "#ff8800", fg = "#000000"},
    {name = "FlashYellow",  bg = "#ffff00", fg = "#000000"},
    {name = "FlashGreen",   bg = "#00ff00", fg = "#000000"},
    {name = "FlashCyan",    bg = "#00ffff", fg = "#000000"},
    {name = "FlashBlue",    bg = "#0088ff", fg = "#ffffff"},
    {name = "FlashPurple",  bg = "#8800ff", fg = "#ffffff"},
    {name = "FlashPink",    bg = "#ff00ff", fg = "#ffffff"},
    {name = "FlashMagenta", bg = "#ff0088", fg = "#ffffff"},
    {name = "FlashLime",    bg = "#88ff00", fg = "#000000"},
}

-- Setup all highlights
for _, color in ipairs(COLORS) do
    vim.api.nvim_set_hl(0, color.name, {
        bg = color.bg,
        fg = color.fg,
        bold = true,
    })
end

---Get next color in rotation
---@return string
function M.get_next_color()
    current_index = (current_index % #COLORS) + 1
    return COLORS[current_index].name
end

---Get specific color by index (1-10)
---@param index number
---@return string
function M.get_color(index)
    return COLORS[((index - 1) % #COLORS) + 1].name
end

---Reset color cycle
function M.reset_cycle()
    current_index = 0
end

---Flash area temporarily
---@param bufnr number
---@param line number
---@param col number
---@param end_col number
---@param duration? number Default: 150ms
---@param color_index? number Optional specific color (1-10)
function M.flash(bufnr, line, col, end_col, duration, color_index)
    duration = duration or 150
    local hl_group = color_index and M.get_color(color_index) or M.get_next_color()

    vim.highlight.range(bufnr, flash_ns, hl_group, {line, col}, {line, end_col})

    vim.defer_fn(function()
        vim.api.nvim_buf_clear_namespace(bufnr, flash_ns, line, line + 1)
    end, duration)
end

---Show persistent debug highlight (doesn't fade)
---@param bufnr number
---@param line number
---@param col number
---@param end_col number
---@param opts? {color_index?: number, text?: string}
---@return number mark_id The extmark ID for later removal
function M.debug_mark(bufnr, line, col, end_col, opts)
    opts = opts or {}
    local hl_group = opts.color_index and M.get_color(opts.color_index) or M.get_next_color()

    local mark_opts = {
        end_col = end_col,
        hl_group = hl_group,
        hl_mode = "combine",
    }

    -- Add virtual text if provided
    if opts.text then
        mark_opts.virt_text = {{" " .. opts.text, "Comment"}}
        mark_opts.virt_text_pos = "eol"
    end

    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, debug_ns, line, col, mark_opts)

    -- Store for tracking
    table.insert(debug_marks, {
        bufnr = bufnr,
        mark_id = mark_id,
        line = line,
        col = col,
        end_col = end_col,
        text = opts.text,
    })

    return mark_id
end

---Remove specific debug mark
---@param bufnr number
---@param mark_id number
function M.remove_debug_mark(bufnr, mark_id)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, debug_ns, mark_id)

    -- Remove from tracking
    for i, mark in ipairs(debug_marks) do
        if mark.bufnr == bufnr and mark.mark_id == mark_id then
            table.remove(debug_marks, i)
            break
        end
    end
end

---Clear all debug marks in buffer
---@param bufnr? number If nil, clears all buffers
function M.clear_debug_marks(bufnr)
    if bufnr then
        vim.api.nvim_buf_clear_namespace(bufnr, debug_ns, 0, -1)
        -- Remove from tracking
        for i = #debug_marks, 1, -1 do
            if debug_marks[i].bufnr == bufnr then
                table.remove(debug_marks, i)
            end
        end
    else
        -- Clear all buffers
        for _, mark in ipairs(debug_marks) do
            pcall(vim.api.nvim_buf_clear_namespace, mark.bufnr, debug_ns, 0, -1)
        end
        debug_marks = {}
    end
end

---Toggle debug mode (shows all marks persistently)
---@return boolean new_state
function M.toggle_debug_mode()
    debug_mode = not debug_mode

    if not debug_mode then
        M.clear_debug_marks()
    end

    vim.notify(
        string.format("Debug marks: %s", debug_mode and "ON" or "OFF"),
        vim.log.levels.INFO
    )

    return debug_mode
end

---Check if debug mode is enabled
---@return boolean
function M.is_debug_mode()
    return debug_mode
end

---Get all active debug marks
---@return table[]
function M.get_debug_marks()
    return vim.deepcopy(debug_marks)
end

---Show mark info (useful for debugging)
---@param bufnr number
---@param line number
---@param col number
function M.inspect_marks_at(bufnr, line, col)
    local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        debug_ns,
        {line, col},
        {line, col},
        {details = true}
    )

    if #marks == 0 then
        vim.notify("No debug marks at this position", vim.log.levels.INFO)
        return
    end

    for _, mark in ipairs(marks) do
        local id, row, col_start, details = mark[1], mark[2], mark[3], mark[4]
        local text = ""
        if details.virt_text and details.virt_text[1] then
            text = " | Text: " .. details.virt_text[1][1]
        end
        vim.notify(string.format(
            "Mark ID: %d | Line: %d | Col: %d-%d | HL: %s%s",
            id, row, col_start, details.end_col or col_start, details.hl_group or "none", text
        ), vim.log.levels.INFO)
    end
end

---Convenience function: flash in debug mode, persist otherwise
---@param bufnr number
---@param line number
---@param col number
---@param end_col number
---@param opts? {duration?: number, color_index?: number, text?: string}
function M.mark(bufnr, line, col, end_col, opts)
    opts = opts or {}

    if debug_mode then
        return M.debug_mark(bufnr, line, col, end_col, opts)
    else
        M.flash(bufnr, line, col, end_col, opts.duration, opts.color_index)
        return nil
    end
end

return M
