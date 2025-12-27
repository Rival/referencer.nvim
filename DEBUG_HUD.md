# Debug HUD

A real-time floating window that displays internal state of the referencer plugin.

## Features

- **Live monitoring** - Updates every 200ms by default
- **Compact display** - Shows key metrics without cluttering your workspace
- **Configurable position** - Place anywhere on screen
- **Auto-updates** - Tracks current buffer's watcher state

## What It Shows

### Symbol Statistics
- **Symbols**: Total number of symbols being tracked
- **Lines**: Number of lines with symbols
- **Stale**: Symbols marked as potentially outdated
- **New**: Symbols pending creation

### State Flags
- **LSP Actualizing**: Whether LSP requests are in progress
- **Buffer Stale**: Whether buffer changed since last LSP update
- **Changetick**: Buffer change counter

### Components
- **Adorners**: Number of active adorners (display renderers)
- **LSP Clients**: Number of attached LSP clients

### Viewport (if enabled)
- **Viewport**: ON/OFF status
- **Range**: Visible line range being processed

## Usage

### Toggle the HUD

```vim
:ReferencerDebugHud
```

Or use the keymap (default: `<leader>td`):

```lua
vim.keymap.set("n", "<leader>td", ":ReferencerDebugHud<CR>")
```

### Configuration

Add to your `referencer.setup()`:

```lua
require("referencer").setup({
    debug_hud = {
        enabled = false,              -- Start disabled (toggle manually)
        position = "top-right",       -- Screen position
        width = 40,                   -- Window width
        height = 15,                  -- Window height
        update_interval = 200,        -- Update frequency (ms)
        border = "rounded",           -- Border style
        row_offset = 3,               -- Offset from top/bottom (avoids notifications)
        col_offset = 0,               -- Offset from left/right
    }
})
```

### Position Options

- `"top-right"` - Upper right corner (default)
- `"top-left"` - Upper left corner
- `"bottom-right"` - Lower right corner
- `"bottom-left"` - Lower left corner

### Border Styles

- `"rounded"` - Rounded corners (default)
- `"single"` - Single line border
- `"double"` - Double line border
- `"solid"` - Solid border
- `"shadow"` - Shadow effect
- `"none"` - No border

### Offset Options

Prevent the HUD from being covered by notifications or other UI elements:

**row_offset** - Offset from top/bottom edge (in lines)
- `0` - No offset (default)
- `3` - 3 lines down from top (recommended for avoiding notifications)
- `5` - More space if you have multiple notification lines

**col_offset** - Offset from left/right edge (in columns)
- `0` - No offset (default)
- `2` - 2 columns in from edge (subtle padding)

**Example - Avoid nvim-notify/noice overlays:**
```lua
debug_hud = {
    position = "top-right",
    row_offset = 3,  -- Push down below notifications
    col_offset = 1,  -- Slight padding from edge
}
```

**Visual Layout with Offsets:**
```
┌────────────────────────────────────────┐
│ [Notification]                         │ ← row 0-2 (notifications)
│                                        │
│                ╭─ Referencer Debug ─╮ │ ← row 3 (HUD starts here with row_offset=3)
│                │ Buffer: 42          │ │
│                │ Symbols: 127        │ │
│                ╰─────────────────────╯ │
│                                        │
│  Your code here...                     │
└────────────────────────────────────────┘
```

## Example HUD Output

```
╭─ Referencer Debug ─╮
│ Buffer: 42
├────────────────────┤
│ Symbols: 127
│ Lines:   89
│ Stale:   3
│ New:     0
├────────────────────┤
│ LSP Actualizing: no
│ Buffer Stale:    no
│ Changetick:      1542
├────────────────────┤
│ Adorners: 2
│ LSP Clients: 1
├────────────────────┤
│ Viewport: ON
│ Range: 45-75
╰────────────────────╯
  Updated: 14:23:47
```

## Use Cases

### Debugging LSP Updates
Watch "LSP Actualizing" to see when the plugin requests symbol data.

### Tracking Stale Symbols
Monitor "Stale" count to understand when symbols need re-fetching.

### Performance Analysis
Use with "Changetick" to correlate buffer changes with plugin updates.

### Viewport Testing
If viewport is enabled, verify which lines are being processed.

## Tips

1. **Position**: Place in a corner that doesn't overlap your code
2. **Update Interval**: Lower values (100ms) for smoother updates, higher (500ms) for less CPU usage
3. **Auto-start**: Set `enabled = true` if you always want it visible
4. **Window Resize**: HUD automatically repositions when terminal is resized
5. **Avoid Notifications**: Use `row_offset = 3` to push the HUD below notification popups (nvim-notify, noice, etc.)
6. **Fine-tune Position**: Combine `row_offset` and `col_offset` to position exactly where you want

## Troubleshooting

### HUD not showing
- Check `debug_hud.enabled` in config
- Verify no errors with `:messages`
- Try `:ReferencerDebugHud` to toggle

### "No watcher active" message
- Open a file with LSP attached
- Ensure referencer is enabled (`:ReferencerToggle`)

### HUD not updating
- Check `update_interval` is reasonable (100-1000ms)
- Verify buffer has an active watcher

## Performance Impact

- **Minimal** - Uses async timer, doesn't block editing
- **~0.5ms per update** - Lightweight queries
- **Toggleable** - Disable when not needed

## Implementation Details

The HUD is implemented as a floating window (`nvim_open_win`) that:
1. Creates a scratch buffer
2. Updates via `vim.loop.new_timer()`
3. Queries current buffer's `BufferLspWatcher`
4. Formats stats as ASCII art
5. Uses non-blocking, scheduled rendering

For more details, see `lua/referencer/debug-hud.lua`.
