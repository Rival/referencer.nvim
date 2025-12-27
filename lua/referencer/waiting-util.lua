local Animations = require("referencer.animations")

local WaitingUtil = {}

---------------------------------------------------------------------
-- Re-export from animations module
---------------------------------------------------------------------
WaitingUtil.symbols = Animations.waiting_symbols
WaitingUtil.apply_highlights = Animations.apply_highlights
WaitingUtil.repeat_symbols = Animations.repeat_symbols

return WaitingUtil
