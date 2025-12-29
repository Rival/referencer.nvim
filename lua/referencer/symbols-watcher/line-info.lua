local ffi = require("ffi")
local logger = require("referencer.logger").for_module("line_info")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")

ffi.cdef[[
    typedef struct {
        int32_t line;
        bool update;
        int32_t _reserved;
    } LineCore;
]]
---@class LineCore
---@field line integer
---@field update boolean
---@field _reserved integer

---@type fun(): LineCore 
local LineCore_t = ffi.typeof("LineCore")

---@class LineInfo
---@field [1] LineCore FFI struct with hot fields
---@field symbols SymbolInfo[] symbols
---@field adorner_data table<SymbolAdorner,any> adorner_data
local M = {}

-- Export array indices as module constants
M.CORE = 1           -- FFI struct (hot fields)

---@param line integer
---@return LineInfo
function M.new(line)
    local core = LineCore_t()
    core.line = line

    return {
        core,         -- [1] FFI struct
        symbols = {},           -- [2] symbols
        adorner_data = {},           -- [3] adorner_data
    }
end

---@param line_info LineInfo
function M.needs_update(line_info)
    line_info[M.CORE].update = true
    logger.debug("Line needs update: %d", line_info[M.CORE].line)
end

---@param line_info LineInfo
function M.if_needs_update(line_info)
    return line_info[M.CORE].update
end

---@param line_info LineInfo
function M.set_line(line_info, line)
    line_info[M.CORE].line = line
end

---@param line LineInfo
---@param adorner SymbolAdorner
function M.get_or_create_adorner_data(line, adorner)
    local data = line.adorner_data[adorner.index]
    if data then
        return data
    end
    data = {}
    line.adorner_data[adorner.index] = data
    return data
end

---@param line LineInfo
---@param adorner SymbolAdorner
function M.get_adorner_data(line, adorner)
    return line.adorner_data[adorner.index]
end

--- Update indices for all symbols on the line
--- Called after adding/removing symbols to keep indices in sync
---@param line_info LineInfo
---@return nil
function M.update_symbol_indices(line_info)
    local symbols = line_info.symbols
    for i = 1, #symbols do
        SymbolInfo.set_index(symbols[i], i)
    end
end

--- Add a single symbol maintaining sorted order by column
--- Uses linear search - optimal for small symbol counts (typically < 10 per line)
---@param line_info LineInfo
---@param symbol SymbolInfo
function M.add_symbol(line_info, symbol)
    local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
    local col = symbol[SymbolInfo.CORE].col
    local symbols = line_info.symbols

    -- Linear search for insertion point (faster than binary for n < 10)
    local insert_idx = #symbols + 1
    for i = 1, #symbols do
        if symbols[i][SymbolInfo.CORE].col > col then
            insert_idx = i
            break
        end
    end

    table.insert(symbols, insert_idx, symbol)

    -- Update indices for all symbols (insertion may have shifted indices)
    M.update_symbol_indices(line_info)

    line_info[M.CORE].update = true
    logger.debug("Added symbol at col=%d (index=%d/%d)", col, insert_idx, #symbols)
end

--- Add multiple symbols (caller must sort afterwards for optimal O(n log n) performance)
--- Use this for batch operations from merge_lines to avoid O(n²) complexity
---@param line_info LineInfo
---@param symbol SymbolInfo
function M.add_symbol_unsorted(line_info, symbol)
    table.insert(line_info.symbols, symbol)
end

return M
