local bit = require("bit")

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

---@enum SymbolKind
local SymbolKind = {
    File          = bit.lshift(1, 0),
    Module        = bit.lshift(1, 1),
    Namespace     = bit.lshift(1, 2),
    Package       = bit.lshift(1, 3),
    Class         = bit.lshift(1, 4),
    Method        = bit.lshift(1, 5),
    Property      = bit.lshift(1, 6),
    Field         = bit.lshift(1, 7),
    Constructor   = bit.lshift(1, 8),
    Enum          = bit.lshift(1, 9),
    Interface     = bit.lshift(1, 10),
    Function      = bit.lshift(1, 11),
    Variable      = bit.lshift(1, 12),
    Constant      = bit.lshift(1, 13),
    String        = bit.lshift(1, 14),
    Number        = bit.lshift(1, 15),
    Boolean       = bit.lshift(1, 16),
    Array         = bit.lshift(1, 17),
    Object        = bit.lshift(1, 18),
    Key           = bit.lshift(1, 19),
    Null          = bit.lshift(1, 20),
    EnumMember    = bit.lshift(1, 21),
    Struct        = bit.lshift(1, 22),
    Event         = bit.lshift(1, 23),
    Operator      = bit.lshift(1, 24),
    TypeParameter = bit.lshift(1, 25),
}

---@class ReferencerFiletypeOption
---@field adorner? SymbolAdornerOpions | string
---@field kinds? table<SymbolKind, SymbolAdornerOpions>


---@class ReferencerConfig
---@field enable? boolean
---@field adorner? SymbolAdornerOpions | string
---@field adorners? SymbolAdornerOpions[]
---@field kinds? table<SymbolKind, SymbolAdornerOpions>
---@field filetype? table<string, ReferencerFiletypeOption>
---@field SymbolKinds? SymbolKind[]
---@field update_debounce_time? integer
---@field auto_update? string
---@field show_no_reference? boolean

local M = {}

M.SymbolKinds = SymbolKind


M.options = {
    enable = true,
    format = " ï %d reference(s)",
    show_no_reference = true,
    -- Traditional virt_text_pos option (used when display_mode is "eol")
    -- Options: "eol", "overlay", "right_align"
    virt_text_pos = "eol",
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

---@param user_opts ReferencerConfig
function M.setup(user_opts)
    M.options = vim.tbl_deep_extend("force", M.options, user_opts or {})

    -- print(vim.inspect(M.options ))
    -- Later, when you need integer conversion:
    local kind_values = {}
    for name, config in pairs(user_opts.kinds) do
        local kind_value = SymbolKind[name]
        if kind_value then
            kind_values[kind_value] = config
        else
            error("Unknown SymbolKind: " .. tostring(name))
        end
    end

    if M.options.color then
        hl_group_from_color = "ReferencerCustomColor"
        vim.api.nvim_set_hl(0, hl_group_from_color, { fg = M.options.color })
    end
end




function M.get_hl_group()
    return hl_group_from_color or M.options.hl_group
end

return M
