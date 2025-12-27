local M = {}

-- NOTE: When this plugin is renamed, these highlight group names should also be updated
-- to match the new plugin name (e.g., ReferencerFlashRed -> NewPluginNameFlashRed)
local current_index = 0
local COLORS = {
    {name = "ReferencerFlashRed",     fg = "#ff0000"},
    {name = "ReferencerFlashOrange",  fg = "#ff8800"},
    {name = "ReferencerFlashYellow",  fg = "#ffff00"},
    {name = "ReferencerFlashGreen",   fg = "#00ff00"},
    {name = "ReferencerFlashCyan",    fg = "#00ffff"},
    {name = "ReferencerFlashBlue",    fg = "#0088ff"},
    {name = "ReferencerFlashPurple",  fg = "#8800ff"},
    {name = "ReferencerFlashPink",    fg = "#ff00ff"},
    {name = "ReferencerFlashMagenta", fg = "#ff0088"},
    {name = "ReferencerFlashLime",    fg = "#88ff00"},
}

-- Setup all highlights
for _, color in ipairs(COLORS) do
    vim.api.nvim_set_hl(0, color.name, {
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

return M
