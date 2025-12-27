---@class AnimationConfig
---@field frames table[] Array of virt_text frames, each frame is {{text, hl_group}, ...}
---@field interval integer Milliseconds per frame
---@field condition? fun(mark: SymbolInfo, adorner_data: table): boolean When to show animation

---@class Animations
local M = {}

---------------------------------------------------------------------
-- Raw symbol sequences (no highlights)
---------------------------------------------------------------------
M.waiting_symbols = {}

-- Braille variations
M.waiting_symbols.braille_classic = {
  "⠋", "⠙", "⠹", "⠸", "⠼",
  "⠴", "⠦", "⠧", "⠇", "⠏",
}

M.waiting_symbols.braille_smooth = {
  "⠁", "⠂", "⠄", "⡀",
  "⢀", "⠠", "⠐", "⠈",
}

M.waiting_symbols.braille_wave = {
  "⠁", "⠃", "⠇", "⠧",
  "⠷", "⠿", "⠻", "⠹",
}

M.waiting_symbols.braille_pulse = {
  "⠁", "⠃", "⠇", "⠏",
  "⠟", "⠿",
  "⠟", "⠏", "⠇", "⠃",
}

M.waiting_symbols.braille_minimal = {
  "⠂", "⠆", "⠒", "⠲",
}

-- Animation symbols
M.waiting_symbols.spinner = {
  "⠋", "⠙", "⠹", "⠸", "⠼",
  "⠴", "⠦", "⠧", "⠇", "⠏",
}

M.waiting_symbols.dots = {
  ".", "..", "...", "....",
}

M.waiting_symbols.pulse = {
  "●", "○", "◌", "○",
}

M.waiting_symbols.hourglass = {
  "⏳", "⌛",
}

M.waiting_symbols.clock = {
  "🕐", "🕑", "🕒", "🕓", "🕔", "🕕",
}

M.waiting_symbols.question = {
  "?",
}

-- Star variations
M.waiting_symbols.stars_morph = {
  "⁎", "∗", "✱", "✳",
}

M.waiting_symbols.stars_sparkle = {
  "✳", "✱", "∗", "⁎", "∗", "✱",
}

-- Single star for color-only animation
M.waiting_symbols.star_pulse = {
  "✳", "✳", "✳", "✳", "✳", "✳", "✳", "✳", "✳", "✳",
}

---------------------------------------------------------------------
-- Highlight schemes (reusable color patterns)
---------------------------------------------------------------------
M.highlight_schemes = {}

M.highlight_schemes.diagnostic_cycle = {
    "DiagnosticHint",
    "DiagnosticInfo",
    "DiagnosticWarn",
    "DiagnosticError",
    "ErrorMsg",
    "DiagnosticError",
    "DiagnosticWarn",
    "DiagnosticInfo",
    "DiagnosticHint",
    "Comment",
}

M.highlight_schemes.pulse_colors = {
    "DiagnosticError",
    "DiagnosticWarn",
    "Comment",
    "DiagnosticWarn",
}

M.highlight_schemes.hourglass_colors = {
    "WarningMsg",
    "ErrorMsg",
}

-- NOTE: When this plugin is renamed, update highlight group names in highlight-util.lua
M.highlight_schemes.rainbow = {
    "ReferencerFlashRed",
    "ReferencerFlashOrange",
    "ReferencerFlashYellow",
    "ReferencerFlashGreen",
    "ReferencerFlashCyan",
    "ReferencerFlashBlue",
    "ReferencerFlashPurple",
    "ReferencerFlashPink",
    "ReferencerFlashMagenta",
    "ReferencerFlashLime",
}

M.highlight_schemes.comment = "Comment"
M.highlight_schemes.info = "DiagnosticInfo"

---------------------------------------------------------------------
-- Utility functions
---------------------------------------------------------------------

--- Combines symbol frames with highlight sequence
--- @param symbols string[]                 -- animation frames
--- @param highlights string[]|string       -- highlight(s)
--- @return table[]                         -- { {symbol, hl}, ... }
function M.apply_highlights(symbols, highlights)
  local result = {}

  local hl_is_table = type(highlights) == "table"

  for i, sym in ipairs(symbols) do
    local hl

    if hl_is_table then
      -- cycle highlights if shorter than symbols
      hl = highlights[((i - 1) % #highlights) + 1]
    else
      hl = highlights
    end

    result[i] = { sym, hl }
  end

  return result
end

--- Repeats symbol sequence N times
function M.repeat_symbols(symbols, times)
  local out = {}
  for _ = 1, times do
    for _, s in ipairs(symbols) do
      out[#out + 1] = s
    end
  end
  return out
end

--- Creates color-only animation from single symbol
--- @param symbol string Single symbol to animate
--- @param highlights string[]|string Highlight scheme to cycle through
--- @return table[] Array of {symbol, hl} pairs
function M.rainbow_symbol(symbol, highlights)
  if type(highlights) == "string" then
    -- Single color, no animation needed
    return {{symbol, highlights}}
  end

  -- Repeat symbol once for each color
  return M.apply_highlights(
    M.repeat_symbols({symbol}, #highlights),
    highlights
  )
end

--- Converts flat {symbol, hl} pairs to virt_text format {{symbol, hl}}
--- @param pairs table[] Array of {symbol, hl} pairs
--- @return table[] Array of virt_text frames
local function to_virt_text_frames(pairs)
  local frames = {}
  for _, pair in ipairs(pairs) do
    frames[#frames + 1] = {{ pair[1], pair[2] }}
  end
  return frames
end

---------------------------------------------------------------------
-- Animation presets (used by formatters)
---------------------------------------------------------------------
---Each animation is an array of {symbol, hl_group} pairs
---Used by waiting_with_spinner() and other animation helpers

M.animations = {
    -- Braille spinners
    spinner_braille = M.apply_highlights(
        M.waiting_symbols.braille_classic,
        M.highlight_schemes.rainbow
    ),

    spinner_braille_smooth = M.apply_highlights(
        M.waiting_symbols.braille_smooth,
        M.highlight_schemes.rainbow
    ),

    -- Simple animations
    dots = M.apply_highlights(
        M.waiting_symbols.dots,
        M.highlight_schemes.comment
    ),

    -- Star animations - morphing shapes
    stars_morph = M.apply_highlights(
        M.waiting_symbols.stars_morph,
        M.highlight_schemes.comment
    ),

    stars_sparkle = M.apply_highlights(
        M.waiting_symbols.stars_sparkle,
        M.highlight_schemes.rainbow
    ),

    -- Star animations - single symbol with rainbow colors
    star_pulse = M.rainbow_symbol("✳", M.highlight_schemes.rainbow),
    low_asterisk = M.rainbow_symbol("⁎", M.highlight_schemes.rainbow),
    star_operator = M.rainbow_symbol("⋆", M.highlight_schemes.rainbow),
    black_star = M.rainbow_symbol("★", M.highlight_schemes.rainbow),
    white_star = M.rainbow_symbol("☆", M.highlight_schemes.rainbow),
}

---------------------------------------------------------------------
-- Legacy exports (backward compatibility - will be removed)
---------------------------------------------------------------------
M.SPINNER_BRAILLE = M.animations.spinner_braille
M.DOTS = M.animations.dots
M.STARS_MORPH = M.animations.stars_morph
M.STARS_SPARKLE = M.animations.stars_sparkle
M.STAR_PULSE = M.animations.star_pulse
M.LOW_ASTERISK_RAINBOW = M.animations.low_asterisk
M.STAR_OPERATOR_RAINBOW = M.animations.star_operator
M.BLACK_STAR_RAINBOW = M.animations.black_star
M.WHITE_STAR_RAINBOW = M.animations.white_star

return M
