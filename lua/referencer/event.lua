---@class EventSubscription
---@field id number
---@field callback function

---@class Event<T>
---@field private subscriptions EventSubscription[]
---@field private next_id number
local Event = {}
Event.__index = Event

---@generic T
---@return Event<T>
function Event.new()
  local self = setmetatable({}, Event)
  self.subscriptions = {}
  self.next_id = 1
  return self
end

---@generic T
---@param self Event<T>
---@param handler fun(data: T)
---@return fun(): nil Unsubscribe function
function Event:subscribe(handler)
  local id = self.next_id
  self.next_id = self.next_id + 1
  
  table.insert(self.subscriptions, {
    id = id,
    callback = handler
  })
  
  -- Closure captures the ID
  return function()
    self:unsubscribe_by_id(id)
  end
end

---@generic T
---@param self Event<T>
---@param handler fun(data: T)
---@return boolean success
function Event:unsubscribe(handler)
  for i, sub in ipairs(self.subscriptions) do
    if sub.callback == handler then
      table.remove(self.subscriptions, i)
      return true
    end
  end
  return false
end

---@generic T
---@param self Event<T>
---@param id number
---@return boolean success
function Event:unsubscribe_by_id(id)
  for i, sub in ipairs(self.subscriptions) do
    if sub.id == id then
      table.remove(self.subscriptions, i)
      return true
    end
  end
  return false
end

---@generic T
---@param self Event<T>
---@param data T
function Event:trigger(data)
  for _, sub in ipairs(self.subscriptions) do
    sub.callback(data)
  end
end

---@generic T
---@param self Event<T>
---@return number
function Event:count()
  return #self.subscriptions
end

---@generic T
---@param self Event<T>
function Event:clear()
  self.subscriptions = {}
end

return Event
