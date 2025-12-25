local bit = require("bit")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")
local logger = require("referencer.logger").for_module("symbol_adorner")

---@class SymbolAdorner
---@field index integer
---@field hl_group SetVirtualTextFunc
---@field hl_mode string
---@field kinds_mask integer
---@field watcher SymbolsWatcher
local SymbolAdorner = {}
SymbolAdorner.__index = SymbolAdorner

---@class SymbolAdornerOpions
---@field type string

---@param watcher SymbolsWatcher
function SymbolAdorner:new(watcher)
    local instance = setmetatable({
        watcher = watcher,
        kinds_mask = 0,
        index = 1,
    }, self)
    return instance
end

---@param opts SymbolAdornerOpions
function SymbolAdorner:init(opts, index, kind_mask)
    self.kinds_mask = kind_mask
    self.index = index
    logger.debug("Adorner initialized with index: %d", index)
end

---@param line integer
---@param col integer
function SymbolAdorner:inspect_position(line, col)

end

function SymbolAdorner:is_type_supported(kind)
    return bit.band(kind, self.kinds_mask) ~= 0
end
---@param symbol SymbolInfo
function SymbolAdorner:is_symbol_supported(symbol)
    return bit.band(symbol[SymbolInfo.SYMBOL_DATA].kind, self.kinds_mask) ~= 0
end

function SymbolAdorner:AddUnsubHook(callback)
self._unsubscribe = self._unsubscribe or {}
table.insert(self._unsubscribe, callback)
end

function SymbolAdorner:Disable()
    for i = 1, #self._unsubscribe, 1 do
        self._unsubscribe[i]()
    end

    self._unsubscribe = {}
end
return SymbolAdorner
