local M = {}

-- Create a unique key for a mark based on line and column
function M.make_mark_key(line, col)
    return string.format("%d:%d", line, col)
end

-- Cache for client capabilities
local client_cache = {}

function M.is_client_supported(client, config)
    -- Check cache first
    if client_cache[client.id] ~= nil then
        return client_cache[client.id]
    end

    -- Check capabilities
    if not client:supports_method("textDocument/documentSymbol") then
        client_cache[client.id] = false
        return false
    end

    if not client:supports_method("textDocument/references") then
        client_cache[client.id] = false
        return false
    end

    -- Check whitelist
    local servers = config.options.lsp_servers
    if servers and not vim.tbl_isempty(servers) then
        if not vim.tbl_contains(servers, client.name) then
            client_cache[client.id] = false
            return false
        end
    end

    -- Client is supported
    client_cache[client.id] = true
    return true
end

function M.clear_client_cache()
    client_cache = {}
end


local superscripts = {
    ["0"]="⁰", ["1"]="¹", ["2"]="²", ["3"]="³", ["4"]="⁴",
    ["5"]="⁵", ["6"]="⁶", ["7"]="⁷", ["8"]="⁸", ["9"]="⁹",
    ["a"]="ᵃ", ["b"]="ᵇ", ["c"]="ᶜ", ["d"]="ᵈ", ["e"]="ᵉ",
    ["f"]="ᶠ", ["g"]="ᵍ", ["h"]="ʰ", ["i"]="ⁱ", ["j"]="ʲ",
    ["k"]="ᵏ", ["l"]="ˡ", ["m"]="ᵐ", ["n"]="ⁿ", ["o"]="ᵒ",
    ["p"]="ᵖ", ["r"]="ʳ", ["s"]="ˢ", ["t"]="ᵗ", ["u"]="ᵘ",
    ["v"]="ᵛ", ["w"]="ʷ", ["x"]="ˣ", ["y"]="ʸ", ["z"]="ᶻ",
}

local subscripts = {
    ["0"]="₀", ["1"]="₁", ["2"]="₂", ["3"]="₃", ["4"]="₄",
    ["5"]="₅", ["6"]="₆", ["7"]="₇", ["8"]="₈", ["9"]="₉",
    ["a"]="ₐ", ["e"]="ₑ", ["h"]="ₕ", ["i"]="ᵢ", ["j"]="ⱼ",
    ["k"]="ₖ", ["l"]="ₗ", ["m"]="ₘ", ["n"]="ₙ", ["o"]="ₒ",
    ["p"]="ₚ", ["s"]="ₛ", ["t"]="ₜ", ["x"]="ₓ",
}
--- Converts integer to superscript unicode string
--- @param number integer
--- @return string
function M.get_number_superscript(number)
    local str = tostring(number)
    local result = {}
    for c in str:gmatch(".") do
        table.insert(result, superscripts[c] or c)
    end
    return table.concat(result)
end
--- Converts integer to subscript unicode string
--- @param number integer
--- @return string
function M.get_number_subscript(number)
    local str = tostring(number)
    local result = {}
    for c in str:gmatch(".") do
        table.insert(result, subscripts[c] or c)
    end
    return table.concat(result)
end
-- Combine any base symbol with decorative marks and optional subscript index
local function augment_symbol_at(text, index, aug)
    aug = aug or {}

    -- combining marks
    local marks = {
        overline  = "\u{305}",  -- ̅
        underline = "\u{332}",  -- ̲
        dot       = "\u{307}",  -- ̇
        circle    = "\u{20DD}", -- ⃝
    }

    -- subscript digits
    local subs = {
        ["0"]="₀",["1"]="₁",["2"]="₂",["3"]="₃",["4"]="₄",
        ["5"]="₅",["6"]="₆",["7"]="₇",["8"]="₈",["9"]="₉",
    }
    local map = {
        ["0"] = "⓪", ["1"] = "①", ["2"] = "②", ["3"] = "③",
        ["4"] = "④", ["5"] = "⑤", ["6"] = "⑥", ["7"] = "⑦",
        ["8"] = "⑧", ["9"] = "⑨",
        ["r"] = "ⓡ", ["e"] = "ⓔ", ["f"] = "ⓕ", ["s"] = "ⓢ",
    }

    -- split into UTF-8 characters
    local chars = {}
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(chars, c)
    end

    -- augment target character
    local target = chars[index]
    if target then
        local decorated = target
        if aug.overline  then decorated = decorated .. marks.overline end
        if aug.underline then decorated = decorated .. marks.underline end
        if aug.dot       then decorated = decorated .. marks.dot end
        if aug.circle    then decorated = decorated .. marks.circle end

        if aug.index then
            local subscript = tostring(aug.index):gsub("%d", subs)
            decorated = decorated .. subscript
        end

        chars[index] = decorated
    end

    return table.concat(chars)
end

-- Debounce function for rate limiting
function M.debounce(fn, delay)
    local timer = nil
    return function(...)
        local args = { ... }
        if timer then
            timer:stop()
            timer = nil
        end

        timer = vim.defer_fn(function()
            fn(unpack(args))
            timer = nil
        end, delay)
    end
end

-- Iterator with separate callbacks for array and hash parts
function M.iter_parts(tbl, array_fn, hash_fn)
    -- Array part
    for i, v in ipairs(tbl) do
        if array_fn then
            array_fn(i, v)
        end
    end

    -- Hash part
    for k, v in pairs(tbl) do
        if type(k) ~= "number" and hash_fn then
            hash_fn(k, v)
        end
    end
end

function M.show_hover_at(text_lines, row, col)
  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text_lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  local win_id = vim.api.nvim_open_win(bufnr, false, {
    relative = 'editor',  -- Position relative to editor (not cursor)
    row = row,            -- Row (0 = top of editor)
    col = col,            -- Column (0 = left edge of editor)
    width = math.max(unpack(vim.tbl_map(function(line) return #line end, text_lines))),
    height = #text_lines,
    style = 'minimal',
    border = 'rounded',
    noautocmd = true,
  })

  -- Auto-close on cursor move
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, {
    buffer = vim.api.nvim_get_current_buf(),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win_id) then
        vim.api.nvim_win_close(win_id, true)
      end
    end,
  })

  return win_id
end

---Flash area with extmark
---@param bufnr number
---@param line number 0-indexed
---@param start_col number 0-indexed
---@param end_col number 0-indexed
---@param opts? {duration: number, hl_group: string}
function M.flash_extmark(bufnr, line, start_col, end_col, opts)
    opts = opts or {}
    local duration = opts.duration or 750
    local hl_group = opts.hl_group or "IncSearch"

    local ns = vim.api.nvim_create_namespace("flash_extmark")

    -- Create extmark with highlight
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, line, start_col, {
        end_col = end_col,
        hl_group = hl_group,
        hl_mode = "combine",
    })

    -- Remove after duration
    vim.defer_fn(function()
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark_id)
    end, duration)
end


---Flash area with extmark
---@param bufnr number
function M.flash_extmarks(bufnr)
    local referencer = require("referencer")
    local helper_flash = require("referencer.helper-flash")
    local swatcher = referencer.get_current_symbols_watcher_for_buffer(bufnr)

    for line, line_info in pairs(swatcher.lines) do
        for i, symbol in ipairs(line_info.symbols) do
            helper_flash.flash(swatcher.buffer, line, 3, 6, 1000, 0)
        end
    end
    -- opts = opts or {}
    -- local duration = opts.duration or 150
    -- local hl_group = opts.hl_group or "IncSearch"
    --
    -- local ns = vim.api.nvim_create_namespace("flash_extmark")
    --
    -- -- Create extmark with highlight
    -- local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, line, start_col, {
    --     end_col = end_col,
    --     hl_group = hl_group,
    --     hl_mode = "combine",
    -- })
    --
    -- -- Remove after duration
    -- vim.defer_fn(function()
    --     pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark_id)
    -- end, duration)
end


function M.resolve_callback_from_options(option, predefined_callbacks, default_option, on_error)
    -- If custom drawer function is provided, use it
    if type(option) == "function" then
        return option
    end

    -- Otherwise, map alignment string to built-in aligner
    if type(option) == "string" then
        local aligner = predefined_callbacks[option]
        if not aligner then
            -- Warn about invalid option, fallback to default
            vim.notify(
                string.format("Invalid option '%s', using '%s'", option, default_option),
                vim.log.levels.WARN
            )
            return predefined_callbacks[default_option]
        end
        return aligner
    end

    -- Handle nil or invalid types - use default
    if option ~= nil then
        vim.notify(
            string.format("Invalid option type '%s', expected string or function", type(option)),
            vim.log.levels.WARN
        )
    end

    return predefined_callbacks[default_option]
end
return M
