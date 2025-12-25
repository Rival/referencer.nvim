# Logging System

Flexible logging system for referencer.nvim with per-module toggles and log levels.

## Configuration

### Basic Setup

```lua
require("referencer").setup({
    -- ... other options ...

    logging = {
        enabled = true,  -- Master switch (disables ALL logging)
        level = "DEBUG", -- "DEBUG" | "INFO" | "WARN" | "ERROR"
        timestamp = true,  -- Show timestamps
        use_notify = false,  -- Use vim.notify instead of print

        -- Per-module toggles
        modules = {
            buffer_watcher = true,         -- BufferLspWatcher
            symbols_watcher = true,        -- SymbolsWatcher
            adorner = false,               -- Base SymbolAdorner
            inline_adorner = false,        -- InlineAdorner
            virtual_lines_adorner = false, -- VirtualLinesAdorner
            line_info = false,             -- LineInfo
            init = true,                   -- Main init.lua
            lsp = true,                    -- LSP requests/responses
        }
    }
})
```

### Quick Debug Configs

```lua
-- Enable all logging
logging = { enabled = true }

-- Errors only
logging = { enabled = true, level = "ERROR" }

-- Only LSP + BufferWatcher
logging = {
    enabled = true,
    modules = {
        buffer_watcher = true,
        lsp = true,
    }
}
```

## Usage in Code

### Option 1: Module Logger (Recommended)

```lua
-- At the top of the file
local logger = require("referencer.logger").for_module("buffer_watcher")

-- Usage
logger.debug("Watcher created: mask=%d", kinds_mask)
logger.info("Actualize start, changetick:%d", start_changedtick)
logger.warn("Symbol has invalid size: %s", symbol_info)
logger.error("Failed to create extmark: %s", error_msg)
```

### Option 2: Global Logger

```lua
local log = require("referencer.logger")

log.debug("buffer_watcher", "Watcher created: %s", vim.inspect(kinds_mask))
log.info("lsp", "Making LSP request for %d symbols", count)
```

### Lazy Evaluation (for expensive computations)

```lua
-- Bad: vim.inspect is called even when logging is disabled
logger.debug("Data: " .. vim.inspect(huge_table))

-- Good: function only called if logging is enabled
logger.debug_lazy(function()
    return "Data: " .. vim.inspect(huge_table)
end)

-- Or check manually
if logger.is_debug() then
    local expensive_data = compute_expensive_data()
    logger.debug("Result: %s", expensive_data)
end
```

## Migration Examples

### Before:
```lua
print("Watcher created:" .. vim.inspect(kinds_mask))
print("===Actualize start, changetick:" .. start_changedtick)
print("SWATCHER: ext_mark CREATED :%d span:%s", mark_id, SymbolInfo.pos_to_string(mark))
```

### After:
```lua
local logger = require("referencer.logger").for_module("buffer_watcher")

logger.debug("Watcher created: mask=%s", vim.inspect(kinds_mask))
logger.info("Actualize start, changetick:%d", start_changedtick)

-- In symbols-watcher.lua
local logger = require("referencer.logger").for_module("symbols_watcher")
logger.debug("ext_mark CREATED: id=%d span=%s", mark_id, SymbolInfo.pos_to_string(mark))
```

## Output Format

With `timestamp = true`:
```
[14:23:45] [DEBUG] [BUFFER_WATCHER] Watcher created: mask=12345
[14:23:45] [INFO] [LSP] Making request for 15 symbols
[14:23:46] [WARN] [SYMBOLS_WATCHER] Symbol has invalid size
[14:23:46] [ERROR] [ADORNER] Failed to create extmark: invalid range
```

Without `timestamp`:
```
[DEBUG] [BUFFER_WATCHER] Watcher created: mask=12345
[INFO] [LSP] Making request for 15 symbols
```

## Usage Scenarios

### 1. Production (no logs)
```lua
logging = { enabled = false }
```

### 2. Normal development
```lua
logging = {
    enabled = true,
    level = "INFO",
    modules = {
        buffer_watcher = true,
        lsp = true,
    }
}
```

### 3. Debug adorner issues
```lua
logging = {
    enabled = true,
    level = "DEBUG",
    timestamp = true,
    modules = {
        inline_adorner = true,
        virtual_lines_adorner = true,
        symbols_watcher = true,
    }
}
```

### 4. LSP debugging only
```lua
logging = {
    enabled = true,
    level = "DEBUG",
    modules = {
        lsp = true,
        buffer_watcher = true,
    }
}
```

## Performance

- **enabled = false**: Zero overhead (early exit in `should_log`)
- **enabled = true, module disabled**: Minimal overhead (single table lookup)
- **enabled = true, module enabled**: Normal overhead (formatting + print)

## Best Practices

1. **Use appropriate levels**:
   - `DEBUG` - Detailed info for debugging (positions, extmarks, etc.)
   - `INFO` - Important events (actualize start/end, LSP requests)
   - `WARN` - Potential issues (invalid sizes, missing data)
   - `ERROR` - Critical errors (failed requests, exceptions)

2. **Name modules consistently**:
   - File: `buffer-watcher.lua` → Module: `"buffer_watcher"`
   - File: `inline-adorner.lua` → Module: `"inline_adorner"`

3. **Use lazy evaluation for expensive operations**:
   ```lua
   logger.debug_lazy(function()
       return "Expensive: " .. vim.inspect(huge_structure)
   end)
   ```

4. **Group related logs**:
   ```lua
   logger.info("=== Actualize start ===")
   -- ... work ...
   logger.info("=== Actualize end ===")
   ```

## Module List

| Module Name | Source File | Purpose |
|-------------|-------------|---------|
| `buffer_watcher` | `buffer-watcher.lua` | Buffer change detection, LSP coordination |
| `symbols_watcher` | `symbols-watcher/symbols-watcher.lua` | Symbol tracking, extmark management |
| `adorner` | `adorners/symbol-adorner.lua` | Base adorner class |
| `inline_adorner` | `adorners/inline-adorner.lua` | Inline virtual text rendering |
| `virtual_lines_adorner` | `adorners/virtual-lines-adorner.lua` | Virtual lines rendering |
| `line_info` | `symbols-watcher/line-info.lua` | Per-line symbol aggregation |
| `init` | `init.lua` | Plugin initialization, setup |
| `lsp` | Various | LSP request/response logging |
