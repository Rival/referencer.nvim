---@class DebugHudConfig
---@field enabled boolean
---@field position "top-right" | "top-left" | "bottom-right" | "bottom-left"
---@field width integer
---@field height integer
---@field update_interval integer Update frequency in milliseconds
---@field border "none" | "single" | "double" | "rounded" | "solid" | "shadow"
---@field style "minimal" | "full"
---@field row_offset integer Offset from top/bottom edge (for avoiding notifications)
---@field col_offset integer Offset from left/right edge

---@class DebugHud
---@field config DebugHudConfig
---@field win integer? Window handle
---@field buf integer? Buffer handle
---@field timer uv_timer_t? Update timer
---@field watcher BufferLspWatcher? Current buffer's watcher
local DebugHud = {}
DebugHud.__index = DebugHud

---@param config? DebugHudConfig
---@return DebugHud
function DebugHud.new(config)
    local default_config = {
        enabled = false,
        position = "top-right",
        width = 40,
        height = 20,  -- Increased from 15 to accommodate animation stats
        update_interval = 200, -- Update every 200ms
        border = "rounded",
        style = "full", -- "minimal" or "full"
        row_offset = 0,  -- Offset from top/bottom (e.g., 3 to avoid notifications)
        col_offset = 0,  -- Offset from left/right
    }

    local instance = setmetatable({
        config = vim.tbl_deep_extend("force", default_config, config or {}),
        win = nil,
        buf = nil,
        timer = nil,
        watcher = nil,
    }, DebugHud)

    return instance
end

---Calculate window position based on config
---@return table opts Window configuration
function DebugHud:get_window_config()
    local width = self.config.width
    local height = self.config.height
    local ui = vim.api.nvim_list_uis()[1]
    local row_offset = self.config.row_offset
    local col_offset = self.config.col_offset

    local row, col
    if self.config.position == "top-right" then
        row = row_offset
        col = ui.width - width - col_offset - 2
    elseif self.config.position == "top-left" then
        row = row_offset
        col = col_offset
    elseif self.config.position == "bottom-right" then
        row = ui.height - height - row_offset - 3
        col = ui.width - width - col_offset - 2
    else -- bottom-left
        row = ui.height - height - row_offset - 3
        col = col_offset
    end

    return {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = self.config.border,
        focusable = false,
        zindex = 50,
    }
end

---Create or update the HUD window
function DebugHud:create_window()
    -- Create buffer if it doesn't exist
    if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
        self.buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(self.buf, "bufhidden", "hide")
        vim.api.nvim_buf_set_option(self.buf, "filetype", "referencer-debug")
        vim.api.nvim_buf_set_name(self.buf, "Referencer Debug HUD")
    end

    -- Create or update window
    if not self.win or not vim.api.nvim_win_is_valid(self.win) then
        local config = self:get_window_config()
        self.win = vim.api.nvim_open_win(self.buf, false, config)

        -- Set window options
        vim.api.nvim_win_set_option(self.win, "winblend", 10)
        vim.api.nvim_win_set_option(self.win, "winhighlight", "Normal:Normal,FloatBorder:FloatBorder")
    end
end

---Format number with color based on value
---@param label string
---@param value number
---@param threshold? number Threshold for yellow/red
---@return string
local function format_metric(label, value, threshold)
    local color = "DiagnosticInfo"
    if threshold and value > threshold then
        color = "DiagnosticWarn"
    end
    return string.format("%-20s %s", label, value)
end

---Get statistics from current buffer's watcher
---@return table stats
function DebugHud:get_stats()
    local bufnr = vim.api.nvim_get_current_buf()
    local M = require("referencer")
    self.watcher = M.get_LspWatcher(bufnr)

    local stats = {
        buffer = bufnr,
        has_watcher = self.watcher ~= nil,
    }

    if not self.watcher then
        return stats
    end

    local sw = self.watcher.symbols_watcher

    -- Count symbols and lines
    local total_symbols = 0
    local line_count = 0
    for _, line_info in pairs(sw.lines) do
        line_count = line_count + 1
        total_symbols = total_symbols + #line_info.symbols
    end

    -- Count stale symbols
    local stale_count = 0
    for _, line_info in pairs(sw.lines) do
        for _, symbol in ipairs(line_info.symbols) do
            local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
            -- Symbol is stale if validated_tick is 0 (needs validation)
            if SymbolInfo.get_validated_tick(symbol) == 0 then
                stale_count = stale_count + 1
            end
        end
    end

    stats.total_symbols = total_symbols
    stats.total_lines = line_count
    stats.stale_symbols = stale_count
    stats.is_actualizing = sw.is_lsp_actualizing
    stats.is_stale = sw.is_stale
    stats.changetick = sw.changetick or 0
    stats.new_symbols = #(sw.new_symbols or {})

    -- Adorner info
    stats.adorner_count = self.watcher.adorners and #self.watcher.adorners or 0

    -- LSP clients
    stats.lsp_clients = self.watcher.lsp_clients and #self.watcher.lsp_clients or 0

    -- Animation stats
    local AnimationManager = require("referencer.animation-manager")
    stats.anim_adorners = AnimationManager.get_adorner_count()
    stats.anim_callbacks = AnimationManager.get_callback_count()

    -- Viewport info
    if sw.viewport and sw.viewport.enabled then
        stats.viewport_enabled = true
        stats.viewport_start = sw.viewport.start_line or 0
        stats.viewport_end = sw.viewport.end_line or 0
    end

    return stats
end

---Render the HUD content
function DebugHud:render()
    if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end

    local stats = self:get_stats()
    local lines = {}

    -- Header
    table.insert(lines, "╭─ Referencer Debug ─╮")

    if not stats.has_watcher then
        table.insert(lines, "│ No watcher active   │")
        table.insert(lines, "╰────────────────────╯")
    else
        -- Buffer info
        table.insert(lines, string.format("│ Buffer: %d", stats.buffer))
        table.insert(lines, "├────────────────────┤")

        -- Symbol stats
        table.insert(lines, string.format("│ Symbols: %d", stats.total_symbols))
        table.insert(lines, string.format("│ Lines:   %d", stats.total_lines))
        table.insert(lines, string.format("│ Stale:   %d", stats.stale_symbols))
        table.insert(lines, string.format("│ New:     %d", stats.new_symbols))

        -- State flags
        table.insert(lines, "├────────────────────┤")
        table.insert(lines, string.format("│ LSP Actualizing: %s", stats.is_actualizing and "YES" or "no"))
        table.insert(lines, string.format("│ Buffer Stale:    %s", stats.is_stale and "YES" or "no"))
        table.insert(lines, string.format("│ Changetick:      %d", stats.changetick))

        -- Components
        table.insert(lines, "├────────────────────┤")
        table.insert(lines, string.format("│ Adorners: %d", stats.adorner_count))
        table.insert(lines, string.format("│ LSP Clients: %d", stats.lsp_clients))

        -- Animation
        table.insert(lines, "├────────────────────┤")
        table.insert(lines, string.format("│ Anim Adorners: %d", stats.anim_adorners))
        table.insert(lines, string.format("│ Anim Callbacks: %d", stats.anim_callbacks))

        -- Viewport (if enabled)
        if stats.viewport_enabled then
            table.insert(lines, "├────────────────────┤")
            table.insert(lines, "│ Viewport: ON")
            table.insert(lines, string.format("│ Range: %d-%d", stats.viewport_start, stats.viewport_end))
        end

        table.insert(lines, "╰────────────────────╯")
    end

    -- Update timestamp
    local time = os.date("%H:%M:%S")
    table.insert(lines, string.format("  Updated: %s", time))

    -- Write to buffer
    vim.api.nvim_buf_set_option(self.buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(self.buf, "modifiable", false)
end

---Start the HUD
function DebugHud:start()
    if self.config.enabled and not self.timer then
        self:create_window()
        self:render()

        -- Create update timer
        self.timer = vim.loop.new_timer()
        self.timer:start(self.config.update_interval, self.config.update_interval, vim.schedule_wrap(function()
            if self.config.enabled then
                self:render()
            end
        end))
    end
end

---Stop the HUD
function DebugHud:stop()
    if self.timer then
        self.timer:stop()
        self.timer:close()
        self.timer = nil
    end

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
        self.win = nil
    end
end

---Toggle the HUD
function DebugHud:toggle()
    self.config.enabled = not self.config.enabled
    if self.config.enabled then
        self:start()
    else
        self:stop()
    end
end

---Update position (useful for window resize)
function DebugHud:update_position()
    if self.win and vim.api.nvim_win_is_valid(self.win) then
        local config = self:get_window_config()
        vim.api.nvim_win_set_config(self.win, config)
    end
end

return DebugHud
