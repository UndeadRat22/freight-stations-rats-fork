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

-- True while at least one station in `entity`'s group is neither the entity
-- itself nor marked for deconstruction: the inventory can live there.
local function has_surviving_mates(entity)
  for _, s in pairs(geometry.reachable_stations(entity.surface, entity, entity.unit_number)) do
    if not s.to_be_deconstructed() then
      return true
    end
  end
  return false
end

-- on_marked_for_deconstruction for stations.
function dismantle.on_marked(event)
  local station = event.entity
  if has_surviving_mates(station) then
    return
  end
  local info = constants.STATION_INFO[station.name]
  local family = info.family
  -- slot iteration, not get_contents(): on a linked container's inventory
  -- get_contents() reads empty even with items in the slots (measured
  -- headless, 2.1.24)
  local contents = {}
  local held = station.get_inventory(LINKED)
  for i = 1, #held do
    local stack = held[i]
    if stack.valid_for_read then
      contents[#contents + 1] = { name = stack.name, count = stack.count, quality = stack.quality }
    end
  end
  held.clear()
  local stand_in = swap(station, constants.dismantling_name(family, info.band))
  if stand_in then
    local inv = stand_in.get_inventory(CHEST)
    for _, stack in ipairs(contents) do
      local inserted = inv.insert(stack)
      stack.count = stack.count - inserted
      if stack.count > 0 then
        stand_in.surface.spill_item_stack({ position = stand_in.position, stack = stack })
      end
    end
    stand_in.order_deconstruction(stand_in.force)
  else
    -- the spot was taken in the same tick: the contents go on the ground
    for _, stack in ipairs(contents) do
      station.surface.spill_item_stack({ position = station.position, stack = stack })
    end
  end
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
  local contents = {}
  local chest = stand_in.get_inventory(CHEST)
  for i = 1, #chest do
    local stack = chest[i]
    if stack.valid_for_read then
      contents[#contents + 1] = { name = stack.name, count = stack.count, quality = stack.quality }
    end
  end
  -- back to the plain family prototype: on_station_built links it with
  -- whatever it touches and the resize pass settles its band
  local station = swap(stand_in, family)
  if station then
    groups.on_station_built(station)
    local inv = station.get_inventory(LINKED)
    for _, stack in ipairs(contents) do
      local inserted = inv.insert(stack)
      stack.count = stack.count - inserted
      if stack.count > 0 then
        station.surface.spill_item_stack({ position = station.position, stack = stack })
      end
    end
  else
    for _, stack in ipairs(contents) do
      stand_in.surface.spill_item_stack({ position = stand_in.position, stack = stack })
    end
  end
end

-- on_player_mined_entity / on_robot_mined_entity / on_entity_died for
-- stations: the last member of a group mined carries the inventory, which
-- goes to the mining buffer/loot, or the ground when there is none.
function dismantle.on_station_mined(entity, loot_inventory)
  if has_surviving_mates(entity) then
    return
  end
  local surface, position = entity.surface, entity.position
  local inv = entity.get_inventory(LINKED)
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      if loot_inventory then
        local inserted = loot_inventory.insert(stack)
        stack.count = stack.count - inserted
      end
      if stack.count > 0 then
        surface.spill_item_stack({ position = position, stack = stack })
      end
    end
  end
  inv.clear()
end

return dismantle
