-- ============================================================================
-- REFERENCER CONFIGURATION PRESETS
-- ============================================================================
--
-- This file provides ready-to-use configuration presets for the referencer plugin.
-- Usage:
--   local presets = require("referencer.config-presets")
--   require("referencer").setup(presets.inline_animated)
--
-- Available presets:
--   - inline_animated: Inline adorner with waiting animations (current production config)
--   - inline_static: Inline adorner without animations (better performance)
--   - virtual_line: Virtual line adorner above code (static)
--   - virtual_line_animated: Virtual line adorner with animated spinners
--

local M = {}

-- ============================================================================
-- COMMON SETTINGS (shared across presets)
-- ============================================================================

local common = {
    enable = true,
    format = "%s",
    show_no_reference = true,
    hl_group = "Comment",
    color = "#335555",
    lsp_servers = {},

    viewport = {
        enabled = true,
        buffer_lines = 10,
        scroll_debounce = 150,
        lazy_load_offscreen = true,
    },

    --global adorners for kinds
    kinds = {
        -- Module = {},
        -- Namespace = {},
        -- Class = {},
        Class = "inline_after",
        Property = {},
        -- Field = "ref_above_line",
        Field = {},
        Method ="inline_after",
        -- Method = {
        --     type = "inline",
        --     align = "eol",
        --     formatter =  "refs",
        -- },
        Function = {},
        -- Variable = {},
        Variable = "ref_sub_script",
        Event = {}
    },

    logging = {
        enabled = true,
        level = "DEBUG",
        timestamp = true,
        use_notify = false,
        modules = {
            buffer_watcher = false,
            symbols_watcher = true,
            adorner = false,
            inline_adorner = false,
            virtual_lines_adorner = false,
            line_info = false,
            init = true,
            lsp = true,
        }
    },

    debug_hud = {
        enabled = false,
        position = "top-right",
        width = 40,
        height = 20,  -- Increased to fit animation stats
        update_interval = 200,
        border = "rounded",
        row_offset = 3,
        col_offset = 0,
    }
}

-- ============================================================================
-- PRESET 1: INLINE WITH ANIMATIONS (Production Config)
-- ============================================================================

M.inline_animated = vim.tbl_deep_extend("force", {}, common, {
    display_mode = "inline",
    animations_enabled = true,

    ---@type InlineAdornerOptions
    adorner = {
        type = "inline",
        align = "after",
        formatter = "refs_waiting_low_asterisk",  -- Animated low asterisk ⁎ rainbow
    },

    adorners = {
        ref_super_script = {
            type = "inline",
            align = "after",
            formatter = "refs_superscript_waiting_animated",
        },
        ref_sub_script = {
            type = "inline",
            align = "after",
            formatter = "refs_subscript_waiting_animated",
        },
        inline_after = {
            type = "inline",
            align = "after",
            formatter = "refs_waiting_animated",
        },
        ref_above_line = {
            type = "virtual_line",
            above = true,
        }
    },

    -- Global adorners for filetypes
    filetype = {
        cs = {},
    },

    -- Global adorners for kinds
    kinds = {
        Class = "inline_after",
        Property = {},
        Field = {},
        Method = "inline_after",
        Function = {},
        Variable = "ref_sub_script",
        Event = {}
    },
})

-- ============================================================================
-- PRESET 2: INLINE WITHOUT ANIMATIONS (Better Performance)
-- ============================================================================

M.inline_static = vim.tbl_deep_extend("force", {}, common, {
    display_mode = "inline",
    animations_enabled = false,  -- Disable animations globally

    ---@type InlineAdornerOptions
    adorner = {
        type = "inline",
        align = "after",
        formatter = "refs",  -- Static formatter (no animation)
    },

    adorners = {
        ref_super_script = {
            type = "inline",
            align = "after",
            formatter = "refs_superscript",  -- Static version
        },
        ref_sub_script = {
            type = "inline",
            align = "after",
            formatter = "refs_subscript",  -- Static version
        },
        inline_after = {
            type = "inline",
            align = "after",
            formatter = "refs",  -- Static version
        },
        ref_above_line = {
            type = "virtual_line",
            above = true,
        }
    },

    filetype = {
        cs = {},
    },

    kinds = {
        Class = "inline_after",
        Property = {},
        Field = {},
        Method = "inline_after",
        Function = {},
        Variable = "ref_sub_script",
        Event = {}
    },
})

-- ============================================================================
-- PRESET 3: VIRTUAL LINE WITHOUT ANIMATIONS
-- ============================================================================

M.virtual_line = vim.tbl_deep_extend("force", {}, common, {
    display_mode = "virtual_line",
    virtual_line_position = "above",
    virtual_line_same_line = false,
    virtual_line_align_to_symbol = false,
    animations_enabled = false,  -- No animations

    ---@type VirtualLineAdornerOptions
    adorner = {
        type = "virtual_line",
        above = true,
        align_first = "most_left",      -- Static aligner
        align_following = "most_left",  -- Static aligner
    },

    adorners = {
        virtual_above = {
            type = "virtual_line",
            above = true,
            align_first = "most_left",
            align_following = "most_left",
        },
        virtual_below = {
            type = "virtual_line",
            above = false,
            align_first = "left",
            align_following = "left",
        },
        inline_fallback = {
            type = "inline",
            align = "after",
            formatter = "refs",
        }
    },

    filetype = {
        cs = {},
    },

    kinds = {
        Class = "virtual_above",
        Property = {},
        Field = {},
        Method = "virtual_above",
        Function = {},
        Variable = "virtual_above",
        Event = {}
    },
})

-- ============================================================================
-- PRESET 4: VIRTUAL LINE WITH ANIMATIONS
-- ============================================================================

M.virtual_line_animated = vim.tbl_deep_extend("force", {}, common, {
    display_mode = "virtual_line",
    virtual_line_position = "above",
    virtual_line_same_line = false,
    virtual_line_align_to_symbol = false,
    animations_enabled = true,  -- Enable animations

    ---@type VirtualLineAdornerOptions
    adorner = {
        type = "virtual_line",
        above = true,
        align_first = "refs_most_left_spinner",      -- Animated formatter!
        align_following = "refs_right_spinner",      -- Animated formatter!
    },

    adorners = {
        virtual_above_left = {
            type = "virtual_line",
            above = true,
            align_first = "refs_most_left_spinner",
            align_following = "refs_left_spinner",
        },
        virtual_above_center = {
            type = "virtual_line",
            above = true,
            align_first = "refs_center_spinner",
            align_following = "refs_center_spinner",
        },
        virtual_above_right = {
            type = "virtual_line",
            above = true,
            align_first = "test_mark_id_left_spinner",
            align_following = "test_mark_id_left_spinner",
        },
        virtual_below = {
            type = "virtual_line",
            above = false,
            align_first = "refs_most_left_spinner",
            align_following = "refs_right_spinner",
        },
        inline_fallback = {
            type = "inline",
            align = "after",
            formatter = "refs_waiting_animated",
        },
        -- Test adorner for symbol-usage.nvim style formatters
        test_usage_style = {
            type = "virtual_line",
            above = true,
            formatter = {
                type = "first_and_following",
                first = "usage_full_spinner",      -- First symbol: "X usages" with spinner
                following = "usage_text_semantic", -- Others: color-coded by usage count
            }
        },
        -- Test adorner for rounded pill style (symbol-usage.nvim advanced)
        test_pill_style = {
            type = "virtual_line",
            above = true,
            formatter = "usage_pill_alt",      -- Beautiful rounded pills with spinner
        }
    },

    filetype = {
        cs = {},
    },

    kinds = {
        Class = "virtual_above_left",
        Property = {},
        Field = {},
        Method = "virtual_above_right",
        Function = {},
        Variable = "test_pill_style",
        Event = {}
    },
})

-- ============================================================================
-- PRESET 5: MINIMAL (Fastest Performance)
-- ============================================================================

M.minimal = {
    enable = true,
    format = "%s",
    show_no_reference = true,
    hl_group = "Comment",
    lsp_servers = {},
    animations_enabled = false,

    adorner = {
        type = "inline",
        align = "after",
        formatter = "refs",
    },

    viewport = {
        enabled = true,
        buffer_lines = 5,
        scroll_debounce = 100,
    },

    logging = {
        enabled = false,  -- Disabled for performance
    },

    debug_hud = {
        enabled = false,
    }
}

-- ============================================================================
-- PRESET 6: MIXED MODE (Virtual Lines + Inline)
-- ============================================================================

M.mixed = vim.tbl_deep_extend("force", {}, common, {
    display_mode = "inline",
    animations_enabled = true,

    adorner = {
        type = "inline",
        align = "after",
        formatter = "refs_waiting_animated",
    },

    adorners = {
        inline_animated = {
            type = "inline",
            align = "after",
            formatter = "refs_waiting_animated",
        },
        virtual_above = {
            type = "virtual_line",
            above = true,
            align_first = "refs_waiting_spinner",
            align_following = "refs_waiting_spinner",
        },
    },

    kinds = {
        -- Classes and Methods get virtual lines
        Class = "virtual_above",
        Method = "virtual_above",

        -- Variables and Functions get inline
        Variable = "inline_animated",
        Function = "inline_animated",

        -- Disable for others
        Property = {},
        Field = {},
        Event = {}
    },
})

return M
