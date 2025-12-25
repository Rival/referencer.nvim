local ffi = require("ffi")
local logger = require("referencer.logger").for_module("line_info")

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
return M
