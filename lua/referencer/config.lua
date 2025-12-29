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


---@alias AutoUpdateMode "none" | "save" | "change" | "both"

---@class ViewportConfig
---@field enabled boolean Enable viewport-based rendering
---@field buffer_lines integer Lines above/below viewport to preload (default: 10)
---@field scroll_debounce integer Debounce delay for scroll events in ms (default: 150)
---@field lazy_load_offscreen boolean Load non-visible symbols in background (default: true)

---@class DebugHudConfig
---@field enabled boolean Enable debug HUD
---@field position "top-right" | "top-left" | "bottom-right" | "bottom-left"
---@field width integer
---@field height integer
---@field update_interval integer Update frequency in milliseconds
---@field border "none" | "single" | "double" | "rounded" | "solid" | "shadow"
---@field row_offset integer Offset from top/bottom edge (for avoiding notifications)
---@field col_offset integer Offset from left/right edge

---@class ReferencerConfig
---@field enable? boolean
---@field adorner? SymbolAdornerOpions | string
---@field adorners? SymbolAdornerOpions[]
---@field kinds? table<SymbolKind, SymbolAdornerOpions>
---@field filetype? table<string, ReferencerFiletypeOption>
---@field SymbolKinds? SymbolKind[]
---@field update_debounce_time? integer
---@field auto_update? AutoUpdateMode
---@field show_no_reference? boolean
---@field logging? ReferencerLoggerConfig
---@field viewport? ViewportConfig
---@field debug_hud? DebugHudConfig

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
    -- Auto-update modes:
    -- • "none"   - No automatic updates (use :lua require('referencer').refresh() manually)
    -- • "save"   - Update on BufWritePost (when you :w) - works for all buffers including background
    -- • "change" - Update on TextChanged/TextChangedI (live updates while typing) - only active buffer
    -- • "both"   - Combines "change" and "save" - live updates + guaranteed refresh on save
    auto_update = "both",
    update_debounce_time = 500,  -- Milliseconds to wait after last change before LSP request (only for "change"/"both" modes)

    -- Viewport rendering (optimization for large files):
    -- Only process symbols visible in viewport, lazy-load the rest
    -- Significantly improves performance on files with 100+ symbols
    viewport = {
        enabled = false,              -- Default: disabled (opt-in for stability)
        buffer_lines = 10,            -- Extra lines above/below viewport to preload
        scroll_debounce = 150,        -- Debounce scroll events (ms)
        lazy_load_offscreen = true,   -- Load non-visible symbols in background
    },

    -- Debug HUD (floating window showing plugin state in real-time)
    debug_hud = {
        enabled = false,              -- Default: disabled (toggle with :ReferencerDebugHud)
        position = "top-right",       -- Position on screen
        width = 40,                   -- Window width
        height = 20,                  -- Window height (increased to fit animation stats)
        update_interval = 200,        -- Update frequency in ms
        border = "rounded",           -- Border style
        row_offset = 0,               -- Offset from top/bottom (e.g., 3 to avoid notifications)
        col_offset = 0,               -- Offset from left/right
    },
}

local hl_group_from_color = nil

---@param user_opts ReferencerConfig
function M.setup(user_opts)
    M.options = vim.tbl_deep_extend("force", M.options, user_opts or {})

    local kind_values = {}
    if user_opts.kinds then
        for name, config in pairs(user_opts.kinds) do
            local kind_value = SymbolKind[name]
            if kind_value then
                kind_values[kind_value] = config
            else
                error("Unknown SymbolKind: " .. tostring(name))
            end
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
