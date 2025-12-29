local bit = require("bit")
local config = require("referencer.config")
local logger_module = require("referencer.logger")
local logger = logger_module.for_module("init")
local BufferLspWatcher = require("referencer.buffer-watcher")
local utils = require("referencer.utils")
local virtual_lines_mode = require("referencer.adorners.virtual-lines-adorner")
local inline_mode = require("referencer.adorners.inline-adorner")
local DebugHud = require("referencer.debug-hud")
require("referencer.highlight-util")  -- Initialize Flash* highlight groups

local ns = vim.api.nvim_create_namespace("Referencer")
local group = vim.api.nvim_create_augroup("Referencer", { clear = true })

-- Global debug HUD instance
local debug_hud = nil


---@class Referencer
local M = {}

---@type ReferencerConfig
local opts = nil
local kinds_mask = 0

---@param  adorner_opts SymbolAdornerOpions
---@return SymbolAdorner
local function create_adorner(symbol_watcher, adorner_opts)
    local current_mode = nil
    if adorner_opts.type == "virtual_line" then
        logger.debug("Creating virtual-lines-mode adorner")
        current_mode = virtual_lines_mode:new(symbol_watcher)
    else
        logger.debug("Creating inline-mode adorner")
        current_mode = inline_mode:new(symbol_watcher)
    end
    return current_mode
end

---@type table<integer,BufferLspWatcher>
local watcher_per_buffer = {}

---@return BufferLspWatcher
function M.get_LspWatcher(buffer)
    local watcher = watcher_per_buffer[buffer]
    if watcher then
        return watcher
    end
end

---@return SymbolsWatcher
function M.get_SymbolsWatcher(buffer)
    local watcher = M.get_LspWatcher(buffer)
    if watcher then
        return watcher.symbols_watcher
    end
end

---@return integer
local function to_lsp_symbol_kinds_mask(symbol_kinds)
    local result = 0
    local function parse_value(value)
        if type(value) == "string" then
            local symbol_kind_lsp = vim.lsp.protocol.SymbolKind[value]
            if not symbol_kind_lsp then
                -- Warn about invalid option
                vim.notify(
                    string.format("Invalid option '%s' for type doesn't exist in LSP", value),
                    vim.log.levels.WARN
                )
                goto continue
            end
            value = symbol_kind_lsp
        else
            if type(value) ~= "number" then
                -- Warn about invalid option
                vim.notify(
                    string.format("Invalid option '%s' for type. It should be string or number", value),
                    vim.log.levels.WARN
                )
                goto continue
            end
        end
        result = bit.bor(result, bit.lshift(1, value - 1))
        ::continue::



    end
    utils.iter_parts(symbol_kinds, function(index, value)
        parse_value(value)
    end, function(kind_name, kind_value)
        parse_value(kind_name)
    end)
    return result
end


---@param watcher BufferLspWatcher
----@param adorner SymbolAdorner
local function resolve_options(options, watcher)
    local global_adorner_opts = options.adorner

    local function is_empty(tbl)
        return next(tbl) == nil
    end

    local function resolve_adorner(value, default_option)
        if type(value) == "boolean" then return value end
        if type(value) == "string" then
            local ad = options.adorners[value]
            if ad then
                return ad
            end
            -- Warn about invalid option, fallback to default
            vim.notify(
                string.format("Invalid option '%s', using '%s'", value, default_option),
                vim.log.levels.WARN
            )
        end

        if is_empty(value) then
            return default_option
        end

        return value
    end

    local default_option = vim.deepcopy(global_adorner_opts)
    local adorners_opts = {}

    local function resolve_options_for_kinds(kinds)
        if kinds then
            for kind, value in pairs(kinds) do
                local kind_adorner_opts = resolve_adorner(value, default_option)
                if kind_adorner_opts ~= false then
                    local kinds_ad_options = adorners_opts[kind_adorner_opts]
                    if not kinds_ad_options then
                        kinds_ad_options = {kinds = {}}
                        adorners_opts[kind_adorner_opts] = kinds_ad_options
                    end
                    table.insert(kinds_ad_options.kinds, kind)
                end
            end
        end
    end


    local kind_options = options.kinds

    if options.filetype then
        local ft = vim.api.nvim_get_option_value("filetype", {buf = watcher.buffer_id})
        local options_for_filetype = options.filetype[ft]
        if options_for_filetype then
            if options_for_filetype.adorner then
                default_option = resolve_adorner(options_for_filetype.adorner, default_option)
            end
            if options_for_filetype.kinds then
                kind_options = vim.tbl_extend("force", kind_options, options_for_filetype.kinds)
            end
        else

        end
    end

    if kind_options then
        resolve_options_for_kinds(kind_options)
    end

    for ad_opts, kind_opts in pairs(adorners_opts) do
        local opts_copy = vim.deepcopy(ad_opts)
        logger.info("Adorner %s parsing for kinds: %s", opts_copy.type, vim.inspect(kind_opts.kinds))
        -- key is options, setting kinds to filter
        local adorner_for_kinds = create_adorner(watcher.symbols_watcher, opts_copy)
        local kind_mask = to_lsp_symbol_kinds_mask(kind_opts.kinds)
        watcher:add_adorner(adorner_for_kinds, opts_copy, kind_mask)
    end
end

local function get_or_create_watcher_and_adorners(buffer)
    ---@type BufferLspWatcher
    local watcher = watcher_per_buffer[buffer]
    if watcher then return watcher end

    -- watcher:add_adorner(create_adorner(watcher.symbols_watcher, opts), opts)

    watcher = BufferLspWatcher.new(buffer, ns, opts, kinds_mask)
    watcher_per_buffer[buffer] = watcher

    -- Create viewport if enabled
    if opts.viewport and opts.viewport.enabled then
        local Viewport = require("referencer.viewport")
        watcher.viewport = Viewport.new(buffer, opts.viewport)
        watcher.symbols_watcher.viewport = watcher.viewport
        logger.debug("Viewport created for buffer %d", buffer)
    end

    resolve_options(opts, watcher)

    -- Debounced update: delays LSP requests until typing stops (reduces spam)
    local debounced_update = utils.debounce(function()
        watcher:actualize_all_lsps(false)
    end, opts.update_debounce_time)

    -- Auto-update mode: "change" - Live updates while typing (only active buffer)
    -- Auto-update mode: "both"   - Combines change + save modes
    if opts.auto_update == "change" or opts.auto_update == "both" then
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = group,
            buffer = buffer,  -- Specific to this buffer
            callback = function (e)
                --when we want to react fast on changes, doing some minimal job
                --fe. whew we join lines with two virt_lines  above our new line there will be two lines,
                --until real aclualiation kicks in debounced_update
                --in order to prevent it we just eraze one line immidiatelly, so it looks less messy
                watcher:actualize_all_lsps(true)

                debounced_update()
            end
        })
    end

    -- Auto-update mode: "save" - Update on file save (works even for background buffers)
    -- Auto-update mode: "both" - Combines change + save modes
    if opts.auto_update == "save" or opts.auto_update == "both" then
        vim.api.nvim_create_autocmd("BufWritePost", {
            group = group,
            buffer = buffer,
            callback = function(e)
                watcher:actualize_all_lsps(false)  -- Full update (no debounce on save)
            end,
        })
    end

    -- Clean up mark state when buffers are deleted
    vim.api.nvim_create_autocmd("BufDelete", {
        group = group,
        buffer = buffer,
        callback = function(e)
            watcher:destroy()
        end
    })

    -- Viewport scroll handling: Update visible range and load newly visible symbols
    if opts.viewport and opts.viewport.enabled and watcher.viewport then
        local debounced_scroll = utils.debounce(function()
            watcher.viewport:update()
            -- Fetch refs for newly visible symbols (cache prevents re-requests for existing symbols)
            watcher:actualize_all_lsps(false, true)
        end, opts.viewport.scroll_debounce)

        vim.api.nvim_create_autocmd("WinScrolled", {
            group = group,
            buffer = buffer,
            callback = debounced_scroll
        })
        logger.debug("WinScrolled autocmd registered for buffer %d", buffer)
    end

    return watcher
end

local enabled = false
function M.enable()
    if enabled then return end
    enabled = true
    local options = config.options

    vim.api.nvim_create_autocmd("LspAttach", {
        pattern = options.pattern,
        group = group,
        callback = function(ev)
            local buffer = ev.buf

            --show all ao attach
            local client = vim.lsp.get_client_by_id(ev.data.client_id)
            if not client or not utils.is_client_supported(client, config) then return end

            local watcher = get_or_create_watcher_and_adorners(buffer)
            watcher:add_client(client)
        end,
    })

    vim.api.nvim_create_autocmd("LspDetach", {
        pattern = options.pattern,
        group = group,
        callback = function(ev)
            local client = vim.lsp.get_client_by_id(ev.data.client_id)
            if not client or not utils.is_client_supported(client, config) then return end
            local watcher = watcher_per_buffer[ev.buf]
            if not watcher then return end

            watcher:remove_client(client)

            -- Clear client cache when LSP detaches
            utils.clear_client_cache()
        end,
    })
end


function M.disable()
    if enabled == false then
        return
    end
    for _, watcher in pairs(watcher_per_buffer) do
        watcher:destroy()
    end
    watcher_per_buffer = {}

    vim.api.nvim_clear_autocmds({ group = group })

    enabled = false
end

function M.toggle()
    if enabled then
        M.disable()
    else
        M.enable()
    end
end

function M.update()
    if enabled then
        -- Don't delete all, just refresh
        local bufnr = vim.api.nvim_get_current_buf()
        local clients = vim.lsp.get_clients({ bufnr = bufnr })
        for _, v in ipairs(clients) do
            M.actualize_from_lsp(v, bufnr)
        end
    end
end


---Toggle debug HUD
function M.toggle_debug_hud()
    if not debug_hud then
        vim.notify("Debug HUD not initialized", vim.log.levels.WARN)
        return
    end
    debug_hud:toggle()
end

---@param user_opts ReferencerConfig
function M.setup(user_opts)
    utils.clear_client_cache()
    config.setup(user_opts)
    opts = config.options

    -- Initialize logger with user config
    if opts.logging then
        logger_module.setup(opts.logging)
    end

    -- Initialize debug HUD
    if opts.debug_hud then
        debug_hud = DebugHud.new(opts.debug_hud)
        if opts.debug_hud.enabled then
            debug_hud:start()
        end

        -- Handle window resize
        vim.api.nvim_create_autocmd("VimResized", {
            group = group,
            callback = function()
                if debug_hud and debug_hud.config.enabled then
                    debug_hud:update_position()
                end
            end,
        })
    end

    kinds_mask = to_lsp_symbol_kinds_mask(opts.kinds or {})
    vim.api.nvim_create_user_command("ReferencerToggle", M.toggle, {})
    vim.api.nvim_create_user_command("ReferencerUpdate", M.update, {})
    vim.api.nvim_create_user_command("ReferencerDebugHud", M.toggle_debug_hud, {})

    if (opts.enable) then
        M.toggle()
    end
end
return M
