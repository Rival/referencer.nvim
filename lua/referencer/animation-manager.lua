--- Global animation manager for all adorners
--- Manages a single timer that updates all adorners with active animations
--- Adorners dynamically register/unregister based on whether they have animating symbols

local config = require("referencer.config")
local logger = require("referencer.logger").for_module("animation_manager")

---@class AnimationManager
local AnimationManager = {
    ---@type table<any, true> Set of adorners currently needing animation updates
    adorners = {},
    ---@type table<function, true> Set of animation callbacks that receive time updates
    callbacks = {},
    ---@type table? UV timer handle
    timer = nil,
    ---@type number Animation update interval in milliseconds
    interval = 50,
}

--- Add an adorner to the animation update list
--- Starts the global timer if this is the first adorner
---@param adorner any Adorner instance (must implement update_animations(now))
function AnimationManager.add_animated_adorner(adorner)
    if AnimationManager.adorners[adorner] then
        -- Already registered
        return
    end

    AnimationManager.adorners[adorner] = true
    logger.debug("Adorner registered for animations: %s", tostring(adorner))

    -- Start timer if this is the first adorner
    if not AnimationManager.timer then
        AnimationManager.start_timer()
    end
end

--- Remove an adorner from the animation update list
--- Stops the global timer if this was the last adorner
---@param adorner any Adorner instance
function AnimationManager.remove_animated_adorner(adorner)
    if not AnimationManager.adorners[adorner] then
        -- Not registered
        return
    end

    AnimationManager.adorners[adorner] = nil
    logger.debug("Adorner unregistered from animations: %s", tostring(adorner))

    -- Stop timer if no more adorners or callbacks
    if vim.tbl_count(AnimationManager.adorners) == 0 and vim.tbl_count(AnimationManager.callbacks) == 0 then
        AnimationManager.stop_timer()
    end
end

--- Add a custom animation callback that receives time updates
--- Starts the global timer if not running
---@param callback fun(time: number) Function to call each animation frame with current time (ms)
---@return fun() cleanup_func Call this function to unregister the callback
function AnimationManager.add_animated_callback(callback)
    if AnimationManager.callbacks[callback] then
        -- Already registered, return existing cleanup
        return function()
            AnimationManager.remove_animated_callback(callback)
        end
    end

    AnimationManager.callbacks[callback] = true
    logger.debug("Animation callback registered")

    -- Start timer if not running
    if not AnimationManager.timer then
        AnimationManager.start_timer()
    end

    -- Return cleanup function
    return function()
        AnimationManager.remove_animated_callback(callback)
    end
end

--- Remove a custom animation callback
--- Stops the global timer if this was the last callback and no adorners remain
---@param callback fun(time: number) The callback function to remove
function AnimationManager.remove_animated_callback(callback)
    if not AnimationManager.callbacks[callback] then
        -- Not registered
        return
    end

    AnimationManager.callbacks[callback] = nil
    logger.debug("Animation callback unregistered")

    -- Stop timer if no more callbacks or adorners
    if vim.tbl_count(AnimationManager.callbacks) == 0 and vim.tbl_count(AnimationManager.adorners) == 0 then
        AnimationManager.stop_timer()
    end
end

--- Start the global animation timer
function AnimationManager.start_timer()
    if AnimationManager.timer then
        -- Already running
        return
    end

    logger.debug("Starting global animation timer (interval=%dms)", AnimationManager.interval)
    AnimationManager.timer = vim.loop.new_timer()
    AnimationManager.timer:start(AnimationManager.interval, AnimationManager.interval, vim.schedule_wrap(function()
        AnimationManager.update_all()
    end))
end

--- Stop the global animation timer
function AnimationManager.stop_timer()
    if not AnimationManager.timer then
        return
    end

    logger.debug("Stopping global animation timer")
    AnimationManager.timer:stop()
    AnimationManager.timer:close()
    AnimationManager.timer = nil
end

--- Update all registered adorners and callbacks
--- Called by the timer every interval
function AnimationManager.update_all()
    -- Check if animations are globally disabled
    if config.options.animations_enabled == false then
        return
    end

    local now = vim.loop.now()

    -- Update each registered adorner
    for adorner, _ in pairs(AnimationManager.adorners) do
        -- Call adorner's update method with current time
        adorner:update_animations(now)
    end

    -- Call each registered callback
    for callback, _ in pairs(AnimationManager.callbacks) do
        -- Call callback with current time
        callback(now)
    end
end

--- Get count of registered adorners (for debugging)
---@return number
function AnimationManager.get_adorner_count()
    return vim.tbl_count(AnimationManager.adorners)
end

--- Get count of registered callbacks (for debugging)
---@return number
function AnimationManager.get_callback_count()
    return vim.tbl_count(AnimationManager.callbacks)
end

return AnimationManager
