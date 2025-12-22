local config = require("referencer.config")
local utils = require("referencer.utils")
local SymbolAdorner = require("referencer.adorners.symbol-adorner")
local SymbolsWatcher = require("referencer.symbols-watcher.symbols-watcher")
local SymbolInfo = require("referencer.symbols-watcher.symbol-info")

---@class InlineAdornerOptions : SymbolAdornerOpions
-- • align : position of virtual text. Possible values:
--     • "eol": right after eol character (default).
--     • "eol_right_align": display right aligned in the window
--         unless the virtual text is longer than the space
--         available. If the virtual text is too long, it is
--         truncated to fit in the window after the EOL character.
--         If the line is wrapped, the virtual text is shown after
--         the end of the line rather than the previous screen
--         line.
--     • "overlay": display over the specified symbol, without
--         shifting the underlying text.
--     • "right_align": display right aligned in the window.
--     • "before": text placed before symbol
--     • "after": text placed after symbol 
---@field align? string 
---@field formatter? GetVirtText | string 
-- • hl_mode : control how highlights are combined with the
--     highlights of the text. Currently only affects virt_text
--     highlights, but might affect `hl_group` in later versions.
--     • "replace": only show the virt_text color. This is the
--         default.
--     • "combine": combine with background text color.
--     • "blend": blend with background text color. Not supported
--     for "before" and "after" align.
---@field hl_mode? string


---@class InlineAdorner : SymbolAdorner
---@field text_formatter GetVirtText  -- Field in the class
---@field set_virtual_text SetVirtualTextFunc  -- Field in the class
---@field align integer 
local InlineAdorner = setmetatable({}, {__index = SymbolAdorner})
InlineAdorner.__index = InlineAdorner


---@class SymbolInfoRef : SymbolInfo
---@field old_refs integer  -- Field in the class

---@alias SetVirtualTextFunc fun(adorner:InlineAdorner, watcher:SymbolsWatcher, line:integer, col: integer, symbol_data: SymbolData)
---@alias GetVirtText fun(watcher:InlineAdorner, line:integer, col: integer, symbol_info: SymbolInfo, adorner_data: any):any[]|nil, integer

-- Built-in alignment functions for virtual lines
---@type table<string,GetVirtText>
InlineAdorner.formatters = {}

local function if_refs_changed(mark, adorner_data)
    local old_refs = adorner_data.refs
    if not old_refs then
        old_refs = - 2
    end
    local refs = #SymbolInfo.get_symbol_data(mark).refs - 1
    adorner_data.refs = refs
    return old_refs ~= refs, refs
end

---@type GetVirtText
function InlineAdorner.formatters.refs(adorner, line, col, mark, adorner_data)
    local yes, refs = if_refs_changed(mark, adorner_data)
    local new_line = nil
    if yes then
        new_line = {{string.format(config.options.format, refs), adorner.hl_group}}
    end
    return new_line, 0
end

---@type GetVirtText
function InlineAdorner.formatters.refs_superscript(adorner, line, col, mark, adorner_data)
    local yes, refs = if_refs_changed(mark, adorner_data)
    local new_line = nil
    if yes then
        new_line = {{string.format(config.options.format, utils.get_number_superscript(refs)), adorner.hl_group}}
    end
    return new_line, 0
end
---@type GetVirtText
function InlineAdorner.formatters.refs_subscript(adorner, line, col, mark, adorner_data)
    local yes, refs = if_refs_changed(mark, adorner_data)
    local new_line = nil
    if yes then
        new_line = {{string.format(config.options.format, utils.get_number_subscript(refs)), adorner.hl_group}}
    end
    return new_line, 0
end

---@param symbol SymbolInfo
---@param adorner InlineAdorner
local function update_visual_ext_mark(adorner, watcher, symbol)
    local mark_core = symbol[SymbolInfo.CORE]
    local adorner_data = SymbolInfo.get_adorner_data(symbol, adorner)
    local virt_text, shift = adorner.text_formatter(adorner, mark_core.line, mark_core.col, symbol, adorner_data)
    if not virt_text then return end

    local col = mark_core.col
    if adorner.align == 1 then
        col = SymbolsWatcher.get_symbol_end_col(symbol)
    end

    local visual_mark_id = adorner_data.visual_mark_id
    if not visual_mark_id then
        -- visual mark is not created yet
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, adorner.watcher.buffer, adorner.watcher.namespace, mark_core.line, col, {
            virt_text = virt_text,
            virt_text_pos = adorner.virt_text_pos,
            hl_mode = adorner.hl_mode,
        })

        if ok then
            print(string.format("Symbol:%s visual mark created:%s", SymbolInfo.id_pos_to_string(symbol), id))
            adorner_data.visual_mark_id = id
        end
    else
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, adorner.watcher.buffer, adorner.watcher.namespace, mark_core.line, col, {
            id = visual_mark_id,
            virt_text = virt_text,
            virt_text_pos = adorner.virt_text_pos,
            hl_mode = adorner.hl_mode,
        })

        -- print(vim.inspect({
        --     id = adorner_data,
        --     virt_text = virt_text,
        --     virt_text_pos = adorner.virt_text_pos,
        --     hl_mode = adorner.hl_mode,
        -- }))

        if ok then
            adorner_data.visual_mark_id = id
            if watcher.is_debug_visual then
            print(string.format("Symbol:%s visual mark changed:%s value %d",
                SymbolInfo.id_pos_to_string(symbol),
                id,
                adorner_data.visual_mark_id))
            end
        else
            print("INLINE_ADORNER: Error creating visual mark:" .. SymbolInfo.pos_to_string(symbol) .. vim.inspect(symbol))

        end
    end
end


---@param  watcher SymbolsWatcher
function InlineAdorner:new(watcher)
    return SymbolAdorner.new(self, watcher)
end
---@param  opts InlineAdornerOptions
function InlineAdorner:init(opts, index, kinds_mask)
    SymbolAdorner.init(self, opts, index,kinds_mask)
    self.hl_group = require("referencer.config").get_hl_group()
    self.text_formatter = utils.resolve_callback_from_options(opts.formatter, InlineAdorner.formatters, "refs")

    self.virt_text_pos = opts.align or "eol"
    self.hl_mode = opts.hl_mode or "replace"
    self.align = opts.align == "after" and 1 or 0

    if opts.align == "eol" or
        opts.align == "eol_right_align" or
        opts.align == "overlay" or
        opts.align == "right_align"
    then
        self.virt_text_pos = opts.align
    else
        if opts.hl_mode == "blend" then
            vim.notify("hl_mode blend is not supported for aligns: 'before' and 'after'")
        end
        self.virt_text_pos = "inline"
    end

    self:Enable()
end

---@param  mark SymbolInfo
function InlineAdorner:destroy_mark(mark)
    local adorner_data = SymbolInfo.get_adorner_data(mark, self)
    local visual_mark_id = adorner_data.visual_mark_id
    if visual_mark_id then
        -- visual mark is created yet
        local ok = pcall(vim.api.nvim_buf_del_extmark, self.watcher.buffer, self.watcher.namespace, visual_mark_id)
        if ok then
            if self.watcher.is_debug_visual then
                print(string.format("visual mark destroyed: %s mark_id:%d", SymbolInfo.pos_to_string(mark), visual_mark_id))
            end
        end
        adorner_data.visual_mark_id = nil
    end
end

---@param line integer
---@param col integer
function SymbolAdorner:inspect_position(line, col)
    local line_info = self.watcher.lines[line]
    if line_info then
        for i, symbol_info in ipairs(line_info.symbols) do
            local s_col = SymbolInfo.get_col(symbol_info)
            local s_end_col = SymbolInfo.get_end_col(symbol_info)
            if col >= s_col and col <= s_end_col then
                utils.flash_extmark(self.watcher.buffer, line, s_col, s_end_col)
                local text = vim.inspect(SymbolInfo.get_symbol_data(symbol_info))
                local lines = vim.split(text, '\n')
                utils.show_hover_at(lines, line + 3, s_end_col + 2)
            end
        end
    end
end

function InlineAdorner:Enable()
    -- self.watcher.OnLineCreated:subscribe(function (args)
    -- end)
    --

    ---@param args SymbolEventArgs
    self:AddUnsubHook(self.watcher.OnSymbolDataUpdated:subscribe(function (args)
        if self:is_symbol_supported(args.symbol) then
            update_visual_ext_mark(self, self.watcher, args.symbol)
        end
    end))

    self:AddUnsubHook(self.watcher.OnActualizeCancelled:subscribe(function ()
        for i, mark in pairs(self.watcher.new_symbols) do
            self:destroy_mark(mark)
        end
    end))

    ---@param args SymbolInfo
    self:AddUnsubHook(self.watcher.OnSymbolMarkDestroyed:subscribe(function (args)
            self:destroy_mark(args)
    end))

    -- self.watcher.OnActualizeEnd:subscribe(function (args)
    --
    -- end)
end


return InlineAdorner
