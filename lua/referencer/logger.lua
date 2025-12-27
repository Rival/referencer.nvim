---@class LogLevel
---@field DEBUG integer
---@field INFO integer
---@field WARN integer
---@field ERROR integer
local LogLevel = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
}

---@class ReferencerLoggerConfig
---@field enabled boolean Global logging toggle
---@field level LogLevel|string|integer Minimum level to log (number 1-4 or string "DEBUG"/"INFO"/"WARN"/"ERROR")
---@field modules table<string, boolean> Per-module toggles
---@field timestamp boolean Show timestamps
---@field use_notify boolean Use vim.notify instead of print

---@class Logger
local M = {}

-- Default configuration
---@type ReferencerLoggerConfig
M.config = {
    enabled = false,  -- Master switch (disables ALL logging)
    level = LogLevel.DEBUG,  -- Show everything by default
    timestamp = false,
    use_notify = false,

    -- Per-module toggles (when enabled=true, these control individual modules)
    modules = {
        buffer_watcher = true,
        symbols_watcher = true,
        adorner = true,
        inline_adorner = false,
        virtual_lines_adorner = false,
        symbol_adorner = false,
        line_info = false,
        init = false,
        lsp = true,  -- LSP requests/responses
    }
}

M.LogLevel = LogLevel

---Setup logger configuration
---@param opts ReferencerLoggerConfig
function M.setup(opts)
    -- Convert string level to number if needed
    if opts and opts.level then
        ---@diagnostic disable-next-line: param-type-mismatch
        local level_type = type(opts.level)
        if level_type == "string" then
            local level_map = {
                DEBUG = LogLevel.DEBUG,
                INFO = LogLevel.INFO,
                WARN = LogLevel.WARN,
                ERROR = LogLevel.ERROR,
            }
            ---@diagnostic disable-next-line: assign-type-mismatch
            ---@type string
            local level_str = opts.level
            ---@diagnostic disable-next-line: assign-type-mismatch
            opts.level = level_map[level_str:upper()] or LogLevel.DEBUG
        end
    end

    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

---Check if logging is enabled for module and level
---@param module string
---@param level integer
---@return boolean
local function should_log(module, level)
    -- Master switch check (fastest path)
    if not M.config.enabled then
        return false
    end

    -- Level check
    if level < M.config.level then
        return false
    end

    -- Module check
    if M.config.modules[module] == false then
        return false
    end

    return true
end

---Format log message with metadata
---@param module string
---@param level integer
---@param msg string
---@return string
local function format_message(module, level, msg)
    local parts = {}

    -- Timestamp
    if M.config.timestamp then
        table.insert(parts, string.format("[%s]", os.date("%H:%M:%S")))
    end

    -- Level
    local level_names = { "DEBUG", "INFO", "WARN", "ERROR" }
    table.insert(parts, string.format("[%s]", level_names[level] or "UNKNOWN"))

    -- Module
    table.insert(parts, string.format("[%s]", module:upper()))

    -- Message
    table.insert(parts, msg)

    return table.concat(parts, " ")
end

---Log message at specified level
---@param module string Module name
---@param level integer Log level
---@param msg string Message (can use string.format style)
---@param ... any Arguments for string.format
local function log(module, level, msg, ...)
    -- Early exit if logging disabled (zero overhead)
    if not should_log(module, level) then
        return
    end

    -- Format message
    local formatted_msg
    if select("#", ...) > 0 then
        formatted_msg = string.format(msg, ...)
    else
        formatted_msg = msg
    end

    local output = format_message(module, level, formatted_msg)

    -- Output
    if M.config.use_notify then
        local notify_level = vim.log.levels.INFO
        if level == LogLevel.ERROR then
            notify_level = vim.log.levels.ERROR
        elseif level == LogLevel.WARN then
            notify_level = vim.log.levels.WARN
        end
        vim.notify(output, notify_level)
    else
        print(output)
    end
end

---Create a logger instance for a module
---@param module_name string
---@return table Logger instance with debug/info/warn/error methods
function M.for_module(module_name)
    return {
        debug = function(msg, ...)
            log(module_name, LogLevel.DEBUG, msg, ...)
        end,

        info = function(msg, ...)
            log(module_name, LogLevel.INFO, msg, ...)
        end,

        warn = function(msg, ...)
            log(module_name, LogLevel.WARN, msg, ...)
        end,

        error = function(msg, ...)
            log(module_name, LogLevel.ERROR, msg, ...)
        end,

        -- Conditional logging (only evaluates if enabled)
        debug_lazy = function(fn)
            if should_log(module_name, LogLevel.DEBUG) then
                log(module_name, LogLevel.DEBUG, fn())
            end
        end,

        -- Check if logging is enabled (for expensive computations)
        is_debug = function()
            return should_log(module_name, LogLevel.DEBUG)
        end,

        is_info = function()
            return should_log(module_name, LogLevel.INFO)
        end,
    }
end

-- Global logging functions (backward compatibility)
function M.debug(module, msg, ...)
    log(module, LogLevel.DEBUG, msg, ...)
end

function M.info(module, msg, ...)
    log(module, LogLevel.INFO, msg, ...)
end

function M.warn(module, msg, ...)
    log(module, LogLevel.WARN, msg, ...)
end

function M.error(module, msg, ...)
    log(module, LogLevel.ERROR, msg, ...)
end

return M
