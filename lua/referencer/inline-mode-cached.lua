local M = {}
local config = require("referencer.config")
local utils = require("referencer.utils")
-- Track marks by extmark ID
local mark_state = {}  -- { [bufnr] = { [mark_id] = { text = "...", symbol_data = ... } } }



local hl_group = nil
local set_virtual_text_for_mode = nil

local function set_virtual_text_inline(bufnr, line, col, text_to_add, symbol_data, ns)

        -- Show inline at specific column
        local inline_pos = config.options.inline_position or "after"
        local target_col = col

        if inline_pos == "after" then
            -- Place after the symbol (at the end of the symbol)
            target_col = col + 1
        elseif inline_pos == "before" then
            -- Place before the symbol
            target_col = col
        end

        local virt_texts = {{ " " .. text_to_add, hl_group}}

        return pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, target_col, {
            virt_text = virt_texts,
            virt_text_pos = "inline",
            hl_mode = "combine",
        })
end

local function set_virtual_text_eol(bufnr, line, col, text_to_add, symbol_data, ns)
        -- Default: end of line or other virt_text_pos modes
        local virt_texts = {{ text_to_add, hl_group }}
        local virt_text_pos = config.options.virt_text_pos or "eol"

        return pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
            virt_text = virt_texts,
            virt_text_pos = virt_text_pos,
            hl_mode = "combine",
        })
end

function M.actualization_start(bufnr, ns)
    -- Clear all marks before rescanning
    -- when line numbers change due to edits
    M.clear_buffer(bufnr, ns)
    if not mark_state[bufnr] then
        mark_state[bufnr] = {}
    end
end

function M.set_virtual_text(bufnr, line, col, text_to_add, symbol_data, ns)
    -- if not mark_state[bufnr] then
    --     mark_state[bufnr] = {}
    -- end
    -- Create new mark
    local ok, mark_id = set_virtual_text_for_mode(bufnr, line, col, text_to_add, symbol_data, ns)
    if ok then
        mark_state[bufnr][mark_id] = {
            text = text_to_add,
            symbol_data = symbol_data
        }
    end
end

function M.remove_virtual_text(bufnr, line, col, ns)

    if not mark_state[bufnr] then
        return
    end

    local key = utils.make_mark_key(line, col)
    local current = mark_state[bufnr][key]

    if not current then
        return
    end

    -- Delete the mark
    if current.mark_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, current.mark_id)
    end

    mark_state[bufnr][key] = nil
end

function M.remove_all_marks_for_line(bufnr, line, ns)
    if not mark_state[bufnr] then
        return
    end

    local keys_to_remove = {}
    for key, mark in pairs(mark_state[bufnr]) do
        if mark.line == line then
            table.insert(keys_to_remove, key)
        end
    end

    for _, key in ipairs(keys_to_remove) do
        local mark = mark_state[bufnr][key]
        if mark.mark_id then
            pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark.mark_id)
        end
        mark_state[bufnr][key] = nil
    end
end

function M.init_buffer(bufnr, ns)
    print("inited for" .. bufnr)
    -- Initialize buffer state if needed
    if not mark_state[bufnr] then
        mark_state[bufnr] = {}
    end
end

function M.clear_buffer(bufnr, ns)
    -- Clear our tracking state
    if mark_state[bufnr] then
        mark_state[bufnr] = nil
    end

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

function M.init(opts, ns)
    hl_group = require("referencer.config").get_hl_group()
    local display_mode = opts.mode.align or "eol"
    if display_mode == "inline" then
        set_virtual_text_for_mode = set_virtual_text_inline
    else
        set_virtual_text_for_mode = set_virtual_text_eol
    end
end
return M
