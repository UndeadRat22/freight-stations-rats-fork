-- on_tick is only registered while one of the next-tick queues below holds
-- work, so the mod costs nothing per tick otherwise. Whether it's registered
-- depends on storage alone, which keeps every client in step: on_load
-- re-registers it from the same queues the server saved.
local ticker = {}

-- storage keys of the queues the handler works through: stations marked for
-- deconstruction, stand-ins to place and cancelled stand-ins to turn back
-- (scripts/dismantle.lua)
local QUEUES = { "marked_stations", "pending_dismantles", "cancelled_stand_ins" }

local handler

-- The on_tick handler to run while there's work (control.lua).
function ticker.set_handler(f)
  handler = f
end

local function busy()
  for _, key in ipairs(QUEUES) do
    local queue = storage[key]
    if queue and queue[1] then
      return true
    end
  end
  return false
end

-- Call after adding to a queue, after the handler ran, and from on_load.
function ticker.update()
  script.on_event(defines.events.on_tick, busy() and handler or nil)
end

return ticker
