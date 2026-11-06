-- Circuit wires survive the script replacing an entity: a station swapped
-- for its resized prototype (scripts/groups.lua), a placer swapped for its
-- station or a placer ghost snapped to its wagon slot (scripts/placer.lua).
-- Works for ghosts too.
local wires = {}

-- Every wire on `entity`, to hand to wires.restore once it's replaced.
function wires.save(entity)
  local saved = {}
  for id, connector in pairs(entity.get_wire_connectors(false)) do
    for _, connection in ipairs(connector.connections) do
      saved[#saved + 1] = { id, connection.target, connection.origin }
    end
  end
  return saved
end

-- A wire whose other end is gone by now is dropped. One between two
-- entities that are both replaced in turn still carries over: the first
-- restore reconnects to the second's old connector, which the second save
-- then picks up.
function wires.restore(entity, saved)
  for _, wire in ipairs(saved) do
    if wire[2].valid then
      entity.get_wire_connector(wire[1], true).connect_to(wire[2], false, wire[3])
    end
  end
end

return wires
