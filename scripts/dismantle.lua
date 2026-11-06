-- Dismantling with robots. Vanilla robots empty a container load by load
-- before they mine it, but never a linked container: a station would be
-- mined at once, its contents spilled as one-item piles. Since a group's
-- capacity is fixed, only ONE case needs help: the LAST station of a group
-- carries the inventory, and when it is marked for deconstruction it
-- becomes a plain container stand-in holding the contents. Robots empty
-- that like any chest and then mine it, which gives the station item back.
-- A station that still has group-mates is simply mined empty: the
-- inventory stays with the group, exactly as it should.
local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
local groups = require("scripts.groups")
local compat = require("scripts.compat")
local spill = require("scripts.spill")

local dismantle = {}

local LINKED = defines.inventory.linked_container_main
local CHEST = defines.inventory.chest

local FAMILY_OF = {} -- stand-in name -> { family, band }
local NAMES = {}
for _, tier in ipairs(constants.TIERS) do
  for _, family in ipairs({ tier.station_h, tier.station_v }) do
    for _, band in ipairs(constants.BANDS[tier.key]) do
      local name = constants.dismantling_name(family, band)
      FAMILY_OF[name] = { family = family, band = band }
      NAMES[#NAMES + 1] = name
    end
  end
end
table.sort(NAMES)

function dismantle.names()
  return NAMES
end

-- Destroys `station` and builds `name` in its place, keeping what a player
-- could notice: health, quality, last user. Raises no events; the caller
-- owns the bookkeeping. Returns nil when the new entity could not be made.
local function swap(station, name)
  local surface, position, force = station.surface, station.position, station.force
  local health, quality, last_user = station.health, station.quality, station.last_user
  station.destroy()
  local new = surface.create_entity({
    name = name,
    position = position,
    force = force,
    quality = quality,
    create_build_effect_smoke = false,
    player = last_user,
  })
  if not new then
    return nil
  end
  new.health = health
  if last_user then
    new.last_user = last_user
  end
  return new
end

-- True while at least one OTHER station in `entity`'s group is neither the
-- entity itself nor marked for deconstruction: the inventory can live
-- there. The entity itself does not count as its own surviving mate -- for
-- the unmarked last-of-group mining path below it is the one being
-- removed, and counting it used to skip the rescue entirely (stranding the
-- shared inventory -- which the engine keeps by link id, so a later group
-- reusing the id inherited the lost items).
local function has_surviving_mates(entity)
  for _, s in pairs(geometry.reachable_stations(entity.surface, entity, entity.unit_number)) do
    if s.unit_number ~= entity.unit_number and not s.to_be_deconstructed() then
      return true
    end
  end
  return false
end

-- on_marked_for_deconstruction for stations.
function dismantle.on_marked(event)
  local station = event.entity
  -- fluid stations are linked by the engine's own fluid segments: they have
  -- no linked inventory to rescue and no stand-in prototype, and the generic
  -- path below would crash reading one
  if constants.TANK_INFO[station.name] then
    return
  end
  if has_surviving_mates(station) then
    return
  end
  local info = constants.STATION_INFO[station.name]
  local family = info.family
  -- through a script inventory rather than name/count/quality tables: real
  -- stacks keep spoilage and durability, which rebuilt tables would reset
  local held = station.get_inventory(LINKED)
  local temp = game.create_inventory(math.min(#held * (info.tier.stack_multiplier or 1), 65535))
  compat.transfer(held, temp)
  spill.inventory(station.surface, station.position, held)
  held.clear()
  local stand_in = swap(station, constants.dismantling_name(family, info.band))
  if stand_in then
    local inv = stand_in.get_inventory(CHEST)
    compat.transfer(temp, inv)
    spill.inventory(stand_in.surface, stand_in.position, temp)
    stand_in.order_deconstruction(stand_in.force)
  else
    -- the spot was taken in the same tick: the contents go on the ground
    spill.inventory(station.surface, station.position, temp)
  end
  temp.destroy()
end

-- on_cancelled_deconstruction for stand-ins: back to a station, linked with
-- whatever it touches, contents first into the (possibly shared) inventory.
function dismantle.on_cancelled(event)
  local stand_in = event.entity
  local info = FAMILY_OF[stand_in.name]
  if not info then
    return
  end
  local family = info.family
  -- out through a script inventory: real stacks keep spoilage and durability
  local chest = stand_in.get_inventory(CHEST)
  local tier = constants.FAMILY_INFO[family].tier
  local temp = game.create_inventory(math.min(#chest * (tier.stack_multiplier or 1), 65535))
  compat.transfer(chest, temp)
  spill.inventory(stand_in.surface, stand_in.position, chest)
  -- back to the plain family prototype: on_station_built links it with
  -- whatever it touches and the resize pass settles its band
  local station = swap(stand_in, family)
  if station then
    groups.on_station_built(station)
    -- the station may have been swapped onto another size band while its
    -- group settled (the same hazard dispatch_built re-finds for): whatever
    -- stands there now receives the contents
    local now = station.surface.find_entities_filtered({ position = station.position, type = "linked-container" })[1]
    local receiver = now or station
    local inv = receiver.get_inventory(LINKED)
    compat.transfer(temp, inv)
    spill.inventory(receiver.surface, receiver.position, temp)
  else
    spill.inventory(stand_in.surface, stand_in.position, temp)
  end
  temp.destroy()
end

-- on_player_mined_entity / on_robot_mined_entity / on_entity_died for
-- stations: the last member of a group mined carries the inventory, which
-- goes to the mining buffer/loot, or the ground when there is none.
-- Deaths pass no inventory at all: a death's loot inventory has nothing to
-- collect it, so contents inserted there were unrecoverable (measured --
-- lab EDGE 10d) -- spilling them keeps them pickable instead.
function dismantle.on_station_mined(entity, loot_inventory)
  if constants.TANK_INFO[entity.name] then
    return
  end
  if has_surviving_mates(entity) then
    return
  end
  local surface, position = entity.surface, entity.position
  local inv = entity.get_inventory(LINKED)
  local index = 0
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      if loot_inventory then
        local inserted = loot_inventory.insert(stack)
        stack.count = stack.count - inserted
      end
      if stack.count > 0 then
        index = index + 1
        spill.stack(surface, position, stack, index)
      end
    end
  end
  inv.clear()
end

return dismantle
