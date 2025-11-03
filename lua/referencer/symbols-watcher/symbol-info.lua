local ffi = require("ffi")

ffi.cdef[[
    typedef struct {
        int32_t mark_id;
        int32_t line;
        int32_t col;
        int32_t end_col;
        int32_t prev_line;
        int32_t prev_col;
        int32_t prev_end_col;
        bool updated;
        bool stale;
        int32_t _reserved;
    } MarkCore;
]]

---@class MarkCore
---@field mark_id integer
---@field line integer
---@field col integer
---@field end_col integer
---@field prev_line integer
---@field prev_col integer
---@field prev_end_col integer
---@field updated boolean
---@field stale boolean
---@field _reserved integer


---@type fun(): MarkCore 
local MarkCore_t = ffi.typeof("MarkCore")


---@class SymbolInfo
---@field [1] MarkCore FFI struct with hot fields
---@field [2] table symbol_data
---@field [3]? vim.api.keyset.set_extmark opts (lazy init)
---@field [4] table<SymbolAdorner,any> adorner_data
local M = {}

-- Export array indices as module constants
M.CORE = 1           -- FFI struct (hot fields)
M.SYMBOL_DATA = 2    -- Lua table
M.OPTS = 3           -- Lua table (lazy)
M.ADORNER_DATA = 4   -- Lua table

-- Local aliases for internal use (optional, for convenience)
local CORE = M.CORE
local SYMBOL_DATA = M.SYMBOL_DATA
local OPTS = M.OPTS
local ADORNER_DATA = M.ADORNER_DATA

---@param line integer
---@param col integer
---@param symbol_data table
---@return SymbolInfo MarkInfo
function M.new(line, col, end_col, symbol_data)
    local core = MarkCore_t()
    core.line = line
    core.col = col
    core.end_col = end_col
    core.mark_id = -1
    core.updated = false
    core.stale = false
    core._reserved = 0

    return {
        core,         -- [1] FFI struct
        symbol_data,  -- [2] anchored
        ---@type vim.api.keyset.set_extmark
        {
            -- • invalidate : boolean that indicates whether to hide the
            --     extmark if the entirety of its range is deleted. For
            --     hidden marks, an "invalid" key is added to the "details"
            --     array of |nvim_buf_get_extmarks()| and family. If
            --     "undo_restore" is false, the extmark is deleted instead.
            invalidate = true,
            -- • undo_restore : Restore the exact position of the mark if
            --     text around the mark was deleted and then restored by
            --     undo. Defaults to true.
            undo_restore = false,
            end_col = core.end_col,
            -- • end_right_gravity : boolean that indicates the direction
            --     the extmark end position (if it exists) will be shifted in
            --     when new text is inserted (true for right, false for
            --         left). Defaults to false.
            --  Basically it allows it to grow when we add text to symbol, 
            --  that allows us instantly invalidate that symbol is changed
            end_right_gravity = true
        },          -- [3] opts
        {},         -- [4] adorner_data
    }
end

-- Fast accessors
function M.get_line(mark)
    return mark[CORE].line
end

function M.set_line(mark, line)
    mark[CORE].line = line
end

function M.get_col(mark)
    return mark[CORE].col
end

function M.set_col(mark, col)
    mark[CORE].col = col
end

function M.if_changed(mark, col)
    local core = mark[CORE]
    return core.col ~= core.prev_col or
        core.end_col ~= core.prev_end_col or
        core.line ~= core.prev_line
end

function M.get_mark_id(mark)
    return mark[CORE].mark_id
end

---@param mark SymbolInfo
function M.set_mark_id(mark, id)
    local core = mark[CORE]
    core.mark_id = id
    mark[OPTS].id = id
end

function M.get_end_col(mark)
    return mark[CORE].end_col
end

---@param mark SymbolInfo
function M.set_end_col(mark, end_col)
    mark[CORE].end_col = end_col
end

---@param mark SymbolInfo
function M.get_prev_end_col(mark)
    return mark[CORE].prev_end_col
end

function M.is_updated(mark)
    return mark[CORE].updated
end

function M.is_stale(mark)
    return mark[CORE].stale
end

function M.is_not_updated(mark)
    return mark[CORE].updated == false
end

function M.set_updated(mark, updated)
    mark[CORE].updated = updated
end

---@param mark SymbolInfo
function M.get_position(mark)
    local core = mark[CORE]
    return core.line, core.col
end

---@param mark SymbolInfo
function M.set_position(mark, line, col, end_col)
    ---@type MarkCore
    local core = mark[CORE]
    core.prev_line = core.line
    core.prev_col = core.col
    core.prev_end_col = core.end_col
    core.line = line
    core.col = col
    core.end_col = end_col
end

--if size changed this tick
---@param mark SymbolInfo
function M.is_tick_size_changed(mark)
    ---@type MarkCore
    local core = mark[CORE]
    local prev_size = core.prev_end_col - core.prev_col
    local current_size = core.end_col - core.col
    return prev_size ~= current_size
end

---@param mark SymbolInfo
function M.is_bad_size(mark)
    ---@type MarkCore
    local core = mark[CORE]
    return core.col >= core.end_col
end

---@param data SymbolData
---@return integer line 
---@return integer col
---@return integer end_col
function M.get_position_from_data(data)
    local pos = data.sym.selectionRange.start
    local end_col = data.sym.selectionRange['end'].character or 1
    local line = pos.line
    local col = pos.character
    return line, col, end_col
end

---@param data SymbolData
function M.is_bad_size_for_data(data)
    local pos = data.sym.selectionRange.start
    local end_col = data.sym.selectionRange['end'].character or 1
    local line = pos.line
    local col = pos.character
    return col >= end_col
end

--if size changed this tick
function M.set_stale(mark)
     mark[CORE].stale = true
end


-- Lua object accessors
---@return SymbolData
function M.get_symbol_data(mark)
    return mark[SYMBOL_DATA]
end

---@param mark SymbolInfo
---@param data SymbolData
function M.set_symbol_data(mark, data, end_col)
    ---@type MarkCore
    local core = mark[CORE]
    mark[SYMBOL_DATA] = data
    mark[OPTS].end_col = end_col
    core.end_col = end_col
    core.updated = true
    --data is fresh so we are not stale
    core.stale = false
end

function M.get_opts(mark)
    if not mark[OPTS] then
        mark[OPTS] = {}
    end
    return mark[OPTS]
end

---return data specific for this adorner instance, it is usefull to store data between updates for this symbol
---@param mark SymbolInfo
---@param adorner SymbolAdorner
function M.get_adorner_data(mark, adorner)
    local adorner_data = mark[ADORNER_DATA]
    ---index is always unique for an adorner of given watcher so we take it by index
    local data = adorner_data[adorner.index]
    if data then
        return data
    end
    data = {}
    adorner_data[adorner.index] = data
    return data
end

-- function M.set_adorner_data(mark, adorner, data)
--     mark[MARK_ADORNER_DATA][adorner] = data
-- end

function M.id_pos_to_string(mark)
    return string.format("%d-[%d|%d-%d]", mark[CORE].mark_id, mark[CORE].line, mark[CORE].col, mark[CORE].end_col)
end
function M.pos_to_string(mark)
   return string.format("[%d|%d-%d]", mark[CORE].line, mark[CORE].col, mark[CORE].end_col)
end

return M
