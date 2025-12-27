local event = require("referencer.event")
local logger = require("referencer.logger").for_module("viewport")

---@class ViewportConfig
---@field enabled boolean
---@field buffer_lines integer Lines above/below to preload
---@field scroll_debounce integer
---@field lazy_load_offscreen boolean

---@class ViewportRange
---@field topline integer 0-indexed first visible line
---@field botline integer 0-indexed last visible line
---@field expanded_topline integer Topline with buffer
---@field expanded_botline integer Botline with buffer

---@class Viewport
---@field buffer integer Buffer number
---@field topline integer First visible line (0-indexed)
---@field botline integer Last visible line (0-indexed)
---@field expanded_topline integer Topline with buffer zone
---@field expanded_botline integer Botline with buffer zone
---@field buffer_lines integer Lines to preload above/below
---@field enabled boolean Viewport filtering enabled
---@field deferred_symbols table[] Symbols queued for background loading
---@field OnViewportChanged Event Event fired when viewport changes
local Viewport = {}
Viewport.__index = Viewport

---Create new viewport tracker for buffer
---@param bufnr integer Buffer number
---@param opts ViewportConfig Configuration options
---@return Viewport
function Viewport.new(bufnr, opts)
    local instance = setmetatable({
        buffer = bufnr,
        topline = 0,
        botline = 0,
        expanded_topline = 0,
        expanded_botline = 0,
        buffer_lines = opts.buffer_lines or 10,
        enabled = opts.enabled or false,
        deferred_symbols = {},
        OnViewportChanged = event.new(),
    }, Viewport)

    -- Initialize viewport range
    instance:update()

    logger.debug("Viewport created for buffer %d: buffer_lines=%d", bufnr, instance.buffer_lines)
    return instance
end

---Update viewport range from current window
function Viewport:update()
    -- Find window showing this buffer
    local winid = vim.fn.bufwinid(self.buffer)
    if winid == -1 then
        logger.warn("No window found for buffer %d", self.buffer)
        return
    end

    local old_top = self.topline
    local old_bot = self.botline

    -- Get visible range (1-indexed from Vim)
    local info = vim.fn.getwininfo(winid)[1]
    if not info then
        logger.error("Failed to get window info for winid %d", winid)
        return
    end

    -- Convert to 0-indexed for LSP
    self.topline = info.topline - 1
    self.botline = info.botline - 1

    -- Expand range with buffer zone
    self.expanded_topline = math.max(0, self.topline - self.buffer_lines)
    self.expanded_botline = self.botline + self.buffer_lines

    logger.debug(
        "Viewport updated: visible=[%d-%d] expanded=[%d-%d]",
        self.topline,
        self.botline,
        self.expanded_topline,
        self.expanded_botline
    )

    -- Fire event if viewport changed
    if old_top ~= self.topline or old_bot ~= self.botline then
        self.OnViewportChanged:trigger({
            topline = self.topline,
            botline = self.botline,
            expanded_topline = self.expanded_topline,
            expanded_botline = self.expanded_botline,
        })
        logger.info("Viewport changed: [%d-%d] -> [%d-%d]", old_top, old_bot, self.topline, self.botline)
    end
end

---Get current visible range
---@return ViewportRange Range with topline, botline, and expanded ranges
function Viewport:get_visible_range()
    return {
        topline = self.topline,
        botline = self.botline,
        expanded_topline = self.expanded_topline,
        expanded_botline = self.expanded_botline,
    }
end

---Check if line is visible (within expanded range)
---@param line integer 0-indexed line number
---@return boolean True if line is in viewport (including buffer zone)
function Viewport:is_line_visible(line)
    local visible = line >= self.expanded_topline and line <= self.expanded_botline
    if not visible then
        logger.debug("Line %d not visible: range=[%d-%d]", line, self.expanded_topline, self.expanded_botline)
    end
    return visible
end

---Check if line is in given range
---@param line integer 0-indexed line number
---@param range ViewportRange Range to check against
---@return boolean True if line is in range
function Viewport:is_line_in_range(line, range)
    return line >= range.expanded_topline and line <= range.expanded_botline
end

---Clear deferred symbols queue
function Viewport:clear_deferred()
    local count = #self.deferred_symbols
    self.deferred_symbols = {}
    if count > 0 then
        logger.debug("Cleared %d deferred symbols", count)
    end
end

return Viewport
