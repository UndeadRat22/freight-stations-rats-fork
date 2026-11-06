-- Dismantling with robots. Vanilla robots empty a container load by load
-- before they mine it, but never a linked container: a station would be
-- mined at once, its contents spilled as one-item piles. So a station
-- marked for deconstruction leaves its group and becomes a plain container
-- stand-in (constants.dismantling_name) holding what the group can't keep.
-- Robots empty that like any chest and then mine it, which gives the
-- station item back. Cancelling the mark turns it back into a station.
local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
local groups = require("scripts.groups")
local compat = require("scripts.compat")
local ticker = require("scripts.ticker")

local dismantle = {}

local LINKED = defines.inventory.linked_container_main
local CHEST = defines.inventory.chest

local FAMILY_OF = {} -- stand-in name -> station family
local NAMES = {}
for family in pairs(constants.FAMILY_NAMES) do
  local name = constants.dismantling_name(family)
  FAMILY_OF[name] = family
  NAMES[#NAMES + 1] = name
end
table.sort(NAMES)

function dismantle.names()
  return NAMES
end

-- Storage written by builds before these queues existed lacks them.
local function queue(key)
  storage[key] = storage[key] or {}
  return storage[key]
end

-- A script inventory big enough for one station's contents at normal stack
-- sizes.
local function hold(station)
  local tier = constants.STATION_INFO[station.name].tier
  return game.create_inventory(tier.slots * (tier.stack_multiplier or 1))
end

-- Moves everything in `held` into `inventory` (nil: none), spills what
-- doesn't fit at `position`, and destroys `held`.
local function unload(held, inventory, surface, position)
  if inventory then
    compat.transfer(held, inventory)
  end
  for i = 1, #held do
    if held[i].valid_for_read then
      surface.spill_item_stack({ position = position, stack = held[i] })
    end
  end
  held.destroy()
end

-- Takes `station` out of its group (its contents stay there as far as they
-- fit, see groups.on_entity_removed) and puts the stand-in in its place,
-- still marked, holding the rest. For a station whose group bookkeeping is
-- missing; recorded members go through convert_group.
local function to_stand_in(station)
  local family = constants.STATION_INFO[station.name].family
  local held = hold(station)
  groups.on_entity_removed(station, held)
  local surface, position = station.surface, station.position
  groups.replace_station(station, constants.dismantling_name(family), nil, function(stand_in)
    compat.transfer(held, stand_in.get_inventory(CHEST))
  end)
  unload(held, nil, surface, position)
end

-- Moves stacks out of `held`, starting at slot `from`, into `inventory`
-- until one doesn't fit; returns the slot to go on from.
local function fill(held, from, inventory)
  for i = from, #held do
    local stack = held[i]
    if stack.valid_for_read then
      local inserted = inventory.insert(stack)
      if inserted < stack.count then
        if inserted > 0 then
          stack.count = stack.count - inserted
        end
        return i
      end
      stack.clear()
    end
  end
  return #held + 1
end

-- Turns `stations`, marked members of group `link_id`, into stand-ins all
-- at once (groups.remove_members), sharing what the rest of the group
-- can't keep between them in turn.
local function convert_group(link_id, stations)
  local first = stations[1]
  local tier = constants.STATION_INFO[first.name].tier
  local surface, position = first.surface, first.position
  local held = game.create_inventory(math.min(#stations * tier.slots * (tier.stack_multiplier or 1), 65535))
  groups.remove_members(link_id, stations, held)
  local from = 1
  local function stock(stand_in)
    if from <= #held then
      from = fill(held, from, stand_in.get_inventory(CHEST))
    end
  end
  for _, station in ipairs(stations) do
    local family = constants.STATION_INFO[station.name].family
    groups.replace_station(station, constants.dismantling_name(family), nil, stock)
  end
  -- only if the stand-ins were short of room, which the sizes rule out
  unload(held, nil, surface, position)
end

-- on_marked_for_deconstruction for stations. Converting resizes the
-- station's group, which replaces its other members, so stations are only
-- noted here and converted next tick, found again by position: a member
-- marked in the same sweep is a new entity by then.
function dismantle.on_marked(event)
  local station = event.entity
  local marked = queue("marked_stations")
  marked[#marked + 1] = { surface = station.surface, position = station.position }
  ticker.update()
end

-- The stations still marked at spot `m` ({surface, position}).
local function marked_at(m)
  local found = {}
  if m.surface.valid then
    for _, station in ipairs(geometry.find_stations(m.surface, { position = m.position })) do
      if station.to_be_deconstructed() then
        found[#found + 1] = station
      end
    end
  end
  return found
end

-- Every group's marked members leave it together, so the group is split
-- and resized once, not once per station. Converting one group only
-- replaces that group's own members, so the others' entities stay valid.
-- Stations without a recorded group go last, one at a time, found again by
-- position: their removal can merge and replace whatever they touch.
local function convert_marked()
  local marked = storage.marked_stations
  if not (marked and marked[1]) then
    return
  end
  storage.marked_stations = {}
  local by_group, order, strays, seen = {}, {}, {}, {}
  for _, m in ipairs(marked) do
    for _, station in ipairs(marked_at(m)) do
      local unit_number = station.unit_number
      if not seen[unit_number] then
        seen[unit_number] = true
        local link_id = storage.station_group[unit_number]
        local group = link_id and storage.groups[link_id]
        if group and group.stations[unit_number] then
          if not by_group[link_id] then
            by_group[link_id] = {}
            order[#order + 1] = link_id
          end
          table.insert(by_group[link_id], station)
        else
          strays[#strays + 1] = m
        end
      end
    end
  end
  for _, link_id in ipairs(order) do
    local stations = {}
    for _, station in ipairs(by_group[link_id]) do
      if station.valid then
        stations[#stations + 1] = station
      end
    end
    if stations[1] then
      convert_group(link_id, stations)
    end
  end
  for _, m in ipairs(strays) do
    for _, station in ipairs(marked_at(m)) do
      to_stand_in(station)
    end
  end
end

-- on_cancelled_deconstruction for stand-ins: back to a station next tick,
-- together with every other stand-in cancelled in the same sweep, so each
-- group they rejoin is resized once (restore_cancelled).
function dismantle.on_cancelled(event)
  local stand_in = event.entity
  local cancelled = queue("cancelled_stand_ins")
  cancelled[#cancelled + 1] = { surface = stand_in.surface, position = stand_in.position }
  ticker.update()
end

-- Turns every cancelled stand-in that is still unmarked back into a
-- station, links them with whatever they touch (groups.on_stations_restored)
-- and only then puts their contents into the groups they ended up in.
local function restore_cancelled()
  local cancelled = storage.cancelled_stand_ins
  if not (cancelled and cancelled[1]) then
    return
  end
  storage.cancelled_stand_ins = {}
  local stations, contents = {}, {}
  for _, c in ipairs(cancelled) do
    if c.surface.valid then
      for _, stand_in in ipairs(c.surface.find_entities_filtered({ position = c.position, name = NAMES })) do
        if not stand_in.to_be_deconstructed() then
          local family = FAMILY_OF[stand_in.name]
          local name = constants.station_name(family, 1)
          local tier = constants.STATION_INFO[name].tier
          local held = game.create_inventory(tier.slots * (tier.stack_multiplier or 1))
          compat.transfer(stand_in.get_inventory(CHEST), held)
          -- unlinked until on_stations_restored gives it a group, so
          -- nothing goes in yet
          -- replace_station returns nil if the restoration build failed
          -- (spot taken in the same tick): the contents then spill via the
          -- unload below, and no station must reach on_stations_restored --
          -- a nil in this array would truncate its ipairs loop.
          local restored = groups.replace_station(stand_in, name)
          if restored then
            stations[#stations + 1] = restored
          end
          contents[#contents + 1] = { held = held, surface = c.surface, position = c.position, family = family }
        end
      end
    end
  end
  groups.on_stations_restored(stations)
  for _, c in ipairs(contents) do
    local now = geometry.find_stations(c.surface, { position = c.position }, c.family)[1]
    unload(c.held, now and now.get_inventory(LINKED), c.surface, c.position)
  end
end

-- A station robots mined before it was converted (marked by something that
-- raised no event, or reached within the tick). Its leftovers go to a
-- stand-in placed next tick, once the station is gone; that stand-in gives
-- the station item, so the robot doesn't.
function dismantle.on_robot_mined(entity, buffer)
  local held = hold(entity)
  groups.on_entity_removed(entity, held)
  local tier = constants.STATION_INFO[entity.name].tier
  buffer.remove({ name = tier.item, quality = entity.quality.name, count = 1 })
  local pending = queue("pending_dismantles")
  pending[#pending + 1] = {
    inventory = held,
    surface = entity.surface,
    position = entity.position,
    force = entity.force,
    quality = entity.quality,
    name = constants.dismantling_name(constants.STATION_INFO[entity.name].family),
  }
  ticker.update()
end

local function place_pending()
  local pending = storage.pending_dismantles
  if not (pending and pending[1]) then
    return
  end
  storage.pending_dismantles = {}
  for _, p in ipairs(pending) do
    if p.surface.valid then
      local stand_in = p.surface.can_place_entity({ name = p.name, position = p.position, force = p.force, build_check_type = defines.build_check_type.manual })
        and p.surface.create_entity({ name = p.name, position = p.position, force = p.force, quality = p.quality, create_build_effect_smoke = false })
      if stand_in then
        stand_in.order_deconstruction(p.force)
        unload(p.inventory, stand_in.get_inventory(CHEST), p.surface, p.position)
      else
        -- something was built on the spot in the meantime. If it is a
        -- station of this family, this was a fast replace (a blueprint or
        -- ghost built over the station, or an immediate rebuild): the
        -- replacement takes over the contents and the stand-in is simply
        -- not needed. Only the station item spills - one visible pickup
        -- instead of vanishing into the mining buffer.
        local family = FAMILY_OF[p.name]
        local now = geometry.find_stations(p.surface, { position = p.position }, family)[1]
        if now then
          unload(p.inventory, now.get_inventory(LINKED), p.surface, p.position)
          local item = constants.STATION_INFO[constants.station_name(family, 1)].tier.item
          p.surface.spill_item_stack({ position = p.position, stack = { name = item, count = 1, quality = p.quality and p.quality.name } })
        else
          -- built over by something else entirely: the station
          -- item and the leftovers go on the ground
          local item = constants.STATION_INFO[constants.station_name(FAMILY_OF[p.name], 1)].tier.item
          p.surface.spill_item_stack({ position = p.position, stack = { name = item, count = 1, quality = p.quality and p.quality.name } })
          unload(p.inventory, nil, p.surface, p.position)
        end
      end
    else
      p.inventory.destroy()
    end
  end
end

function dismantle.on_tick()
  restore_cancelled()
  convert_marked()
  place_pending()
end

return dismantle
