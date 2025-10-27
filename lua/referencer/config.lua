---@class DisplayMode
---@field eol integer
---@field inline integer
---@field virtual_line_above integer
---@field virtual_line_below integer

---@class Alignment
---@field most_left integer
---@field left integer
---@field center integer
---@field right integer
local M = {}

M.DisplayMode = {
    eol = 1,
    inline = 2,
    virtual_line_above = 3,
    virtual_line_below = 4,
}
M.Alignment = {
    most_left = 1,
    left = 2,
    center = 3,
    right = 4,
}

M.options = {
    enable = false,
    format = " ï %d reference(s)",
    show_no_reference = true,
    -- Display mode determines how references are shown
    -- Options: "eol" (end of line), "inline", "virtual_line_above", "virtual_line_below"
    -- display_mode = DisplayMode.eol,
    -- For "virtual_line" mode: show on same line or separate virtual line
    -- true = end-of-line on same line, false = separate virtual line above/below
    virtual_line_same_line = false,
    -- Simple string alignment for virtual lines (when virtual_line_same_line = false)
    -- Options: "most_left", "left", "center", "right"
    -- These are easier than using drawer functions
    virtual_line_first_alignment = "most_left",   -- For first symbol on a line
    virtual_line_following_alignment = "most_left",  -- For subsequent symbols
    -- Advanced: Custom drawer functions for virtual lines (overrides alignment strings)
    -- These receive (symbol_data, start_col, end_col, symbol_start_col, symbol_end_col)
    -- and return { text = "...", col = position }
    virtual_lie_first_drawer = nil,  -- If set, overrides virtual_line_first_alignment
    virtual_line_following_drawer = nil,  -- If set, overrides virtual_line_following_alignment
    -- For "inline" mode: position relative to the symbol
    -- Options: "after", "before"
    inline_position = "after",
    -- Traditional virt_text_pos option (used when display_mode is "eol")
    -- Options: "eol", "overlay", "right_align"
    virt_text_pos = "eol",
    kinds = { 5, 6, 8, 12, 13, 14, 23, },
    hl_group = "Comment",
    color = nil,
    pattern = nil,
    lsp_servers = {},
    -- mode = {
    --     style = "inline",
    -- Options: "after", "before"
    -- Options: "eol", "overlay", "right_align"
    -- • "eol": right after eol character (default).
    --     • "eol_right_align": display right aligned in the window
    --         unless the virtual text is longer than the space
    --         available. If the virtual text is too long, it is
    --         truncated to fit in the window after the EOL character.
    --         If the line is wrapped, the virtual text is shown after
    --         the end of the line rather than the previous screen
    --         line.
    --     • "overlay": display over the specified column, without
    --         shifting the underlying text.
    --     • "right_align": display right aligned in the window.
    --     • "inline": display at the specified column, and shift the
    --         buffer text to the right as needed.
    --     align = "eol"
    -- }
    mode = {
        style = "virtual_line",
        position = "above",
        align_first = "most_left",
        align_following = "most_left"
    },
    auto_update = "change",  -- "none", "save", "change"
    update_debounce_time = 500,  -- how long to wait after text update
}

local hl_group_from_color = nil

function M.setup(user_opts)
    M.options = vim.tbl_deep_extend("force", M.options, user_opts or {})

    if M.options.color then
        hl_group_from_color = "ReferencerCustomColor"
        vim.api.nvim_set_hl(0, hl_group_from_color, { fg = M.options.color })
    end
end

function M.get_hl_group()
    return hl_group_from_color or M.options.hl_group
end

return M
