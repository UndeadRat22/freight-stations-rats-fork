-- Swaps a just-built placer for the real (non-rotatable) station or balancer
-- it represents, then -- only for drag-built or blueprint/robot builds, never
-- a single deliberate placement -- fills either open gap next to a station
-- with a balancer if a matching station already sits exactly one tile away.
local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
local rails = require("scripts.rails")
local ticker = require("scripts.ticker")
local wires = require("scripts.wires")

local placer = {}

-- For every placement check: the default build check (ghost_revive) refuses
-- spots with loose items on the ground, which a player can build over
-- (confirmed headless, 2.0.77).
local MANUAL = defines.build_check_type.manual

local PLACER_TIER = {} -- placer name -> tier, station placers
local BALANCER_PLACER_TIER = {} -- placer name -> tier, balancer placers
local ENDS = {} -- station family -> the two ends to probe for an auto-connect neighbour
local STATION_BALANCER = {} -- station family -> balancer prototype to bridge it with
local BALANCER_ITEM = {} -- balancer prototype -> its item
local BALANCER_GHOSTS = {} -- balancer prototype -> the ghost names that build it
local DIRECTION_NAMES = {} -- tier.key -> {direction -> {station, balancer}}
-- ghost name -> { tier, axes = function(direction) -> row axes }, for every
-- entity that sits in the gap between two stations
local GAP_GHOSTS = {}
local NORTH_SOUTH = {
  [defines.direction.north] = true,
  [defines.direction.south] = true,
}

local function both_axes()
  return { "x", "y" }
end

-- placers: north/south make a horizontal (x) row piece
local function placer_axes(direction)
  return { NORTH_SOUTH[direction] and "x" or "y" }
end

-- undergrounds face across the track: north/south-facing ones sit in an x row
local underground_axes = placer_axes

for _, tier in ipairs(constants.ALL_TIERS) do
  if tier.balancer_placer then
    GAP_GHOSTS[tier.balancer_placer] = { tier = tier, item = tier.balancer_item, axes = placer_axes }
    GAP_GHOSTS[tier.balancer_h] = { tier = tier, item = tier.balancer_item, axes = function()
      return { "x" }
    end }
    GAP_GHOSTS[tier.balancer_v] = { tier = tier, item = tier.balancer_item, axes = function()
      return { "y" }
    end }
  else
    -- the iron stock balancer links on all four sides; fluid balancers turn
    -- (north/south: in an x row), see constants.TANK_TIERS
    GAP_GHOSTS[tier.balancer_h] = { tier = tier, item = tier.balancer_item, axes = tier.fluid and placer_axes or both_axes }
  end
  GAP_GHOSTS[tier.underground] = { tier = tier, item = tier.underground_item, axes = underground_axes }
end

local GAP_GHOST_NAMES = {}
for name in pairs(GAP_GHOSTS) do
  GAP_GHOST_NAMES[#GAP_GHOST_NAMES + 1] = name
end
table.sort(GAP_GHOST_NAMES)

for _, tier in ipairs(constants.ALL_TIERS) do
  PLACER_TIER[tier.placer] = tier
  if tier.balancer_placer then
    BALANCER_PLACER_TIER[tier.balancer_placer] = tier
  end
  ENDS[tier.station_h] = { { dx = 1, dy = 0 }, { dx = -1, dy = 0 } }
  ENDS[tier.station_v] = { { dx = 0, dy = 1 }, { dx = 0, dy = -1 } }
  STATION_BALANCER[tier.station_h] = tier.balancer_h
  STATION_BALANCER[tier.station_v] = tier.balancer_v
  BALANCER_ITEM[tier.balancer_h] = tier.balancer_item
  BALANCER_ITEM[tier.balancer_v] = tier.balancer_item
  BALANCER_GHOSTS[tier.balancer_h] = { tier.balancer_h, tier.balancer_placer }
  BALANCER_GHOSTS[tier.balancer_v] = { tier.balancer_v, tier.balancer_placer }
  DIRECTION_NAMES[tier.key] = {
    [defines.direction.north] = { tier.station_h, tier.balancer_h },
    [defines.direction.south] = { tier.station_h, tier.balancer_h },
    [defines.direction.east] = { tier.station_v, tier.balancer_v },
    [defines.direction.west] = { tier.station_v, tier.balancer_v },
  }
end

local HALF_LONG = constants.STATION_TILES / 2
local GAP = constants.GAP

function placer.is_placer(name)
  return constants.PLACERS[name] == true
end

-- Ghost names placer.on_gap_ghost_built handles (control.lua's event filter).
function placer.gap_ghost_names()
  return GAP_GHOST_NAMES
end

function placer.is_gap_ghost(name)
  return GAP_GHOSTS[name] ~= nil
end

-- Stations or tanks of `family` matching `spec` (find_entities_filtered
-- parameters without a name or type).
local function find_family(surface, spec, family)
  local info = constants.TANK_INFO[family]
  if info then
    spec.name = info.name
    return surface.find_entities_filtered(spec)
  end
  return geometry.find_stations(surface, spec, family)
end

-- The gap tile at the `d` end ({dx, dy}, see ENDS) of a station centred at
-- `position`.
local function gap_position(position, d)
  return {
    x = position.x + d.dx * (HALF_LONG + GAP / 2),
    y = position.y + d.dy * (HALF_LONG + GAP / 2),
  }
end

-- Recorded in on_pre_build (player builds only -- robots/scripts never fire
-- it) and consumed the moment this placer's own build event arrives.
function placer.note_pre_build(event)
  local player = game.get_player(event.player_index)
  storage.pending_build_mode[event.player_index] = {
    created_by_moving = event.created_by_moving,
    -- A blueprint (copy, cut, or the blueprint tool) in the cursor: its
    -- layout is already deliberate, so it always auto-connects. Not read off
    -- the event: its flip_horizontal/flip_vertical are documented as nil
    -- outside blueprints but are set for every build (2.0.77).
    from_blueprint = player ~= nil and player.is_cursor_blueprint(),
  }
end

-- Takes (and clears) what on_pre_build recorded for this player's current
-- placement, or nil if nothing was recorded.
function placer.consume_pre_build(player_index)
  local pending = storage.pending_build_mode[player_index]
  storage.pending_build_mode[player_index] = nil
  return pending
end

-- player_index is nil for robot/space-platform/script builds, which have no
-- on_pre_build pairing at all -- always auto-connect those, since a
-- blueprint or script-driven layout is inherently deliberate.
-- Returns connect, dragged.
local function should_auto_connect(player_index)
  if not player_index then
    return true, false
  end
  local pending = placer.consume_pre_build(player_index)
  if not pending then
    return false, false
  end
  return pending.created_by_moving or pending.from_blueprint, pending.created_by_moving
end

-- Drag-building spaces entities by what's in the world, and the 7-tile
-- placer is replaced by a 6-tile station at once, so the next dragged placer
-- would land in the empty gap tile, flush against the station. While a
-- player drags, each open gap next to a new station holds an invisible
-- reservation that only placers collide with (prototypes/placer.lua). The
-- next station turns it into a balancer; leftovers at the row ends are
-- cleared by placer.expire_reservations shortly after the drag stops.
local RESERVATION = "freight-station-gap-reservation"
local RESERVATION_TICKS = 120

local function clear_reservations_at(surface, position)
  for _, e in ipairs(surface.find_entities_filtered({ position = position, name = RESERVATION })) do
    e.destroy()
  end
end

local function reserve_gap(surface, position, force, player_index)
  if surface.count_entities_filtered({ position = position, name = RESERVATION }) > 0 then
    return
  end
  local e = surface.create_entity({ name = RESERVATION, position = position, force = force })
  if e then
    storage.gap_reservations[player_index] = storage.gap_reservations[player_index] or {}
    table.insert(storage.gap_reservations[player_index], e)
  end
end

function placer.expire_reservations(tick)
  for player_index, list in pairs(storage.gap_reservations) do
    if tick - (storage.last_drag_tick[player_index] or 0) >= RESERVATION_TICKS then
      for _, e in ipairs(list) do
        if e.valid then
          e.destroy()
        end
      end
      storage.gap_reservations[player_index] = nil
    end
  end
end

-- Drops a player's build bookkeeping and gap reservations, for a player
-- who left the game or was removed.
function placer.forget_player(player_index)
  storage.pending_build_mode[player_index] = nil
  storage.last_drag_tick[player_index] = nil
  for _, e in ipairs(storage.gap_reservations[player_index] or {}) do
    if e.valid then
      e.destroy()
    end
  end
  storage.gap_reservations[player_index] = nil
end

-- An auto-placed balancer costs one balancer item, like any other build: a
-- player building by hand pays from their inventory (free in cheat mode).
-- Without one, or for robot/script builds, it becomes a ghost for robots to
-- fill, so the connection is still requested but never free.
local function place_balancer(surface, position, balancer, direction, force, player)
  if player and (player.cheat_mode or player.remove_item({ name = BALANCER_ITEM[balancer], count = 1 }) > 0) then
    surface.create_entity({
      name = balancer,
      position = position,
      direction = direction,
      force = force,
      player = player,
      raise_built = true,
    })
  else
    -- a wide tier's balancer: robots build it through its placer (scripts/ghosts.lua)
    local swap = constants.PLACER_OF[balancer]
    surface.create_entity({
      name = "entity-ghost",
      inner_name = swap and swap.placer or balancer,
      position = position,
      direction = swap and swap.direction or direction,
      force = force,
      player = player,
    })
  end
end

-- A message at `position`: flying text for `player`, else drawn on the map
-- for a few seconds.
local function tell(surface, position, player, message)
  if player then
    player.create_local_flying_text({ text = message, position = position })
  else
    rendering.draw_text({
      surface = surface,
      target = position,
      text = message,
      color = { r = 1, g = 0.3, b = 0.3 },
      time_to_live = 180,
      alignment = "center",
    })
  end
end

-- The fluid a tank holds (its row's), or nil when it's empty.
local function fluid_of(tank)
  return (next(tank.get_fluid_contents()))
end

-- Takes plain values, not the station: building the first balancer merges
-- groups, which swaps the station for a resized prototype (scripts/groups.lua)
-- and leaves any reference to it invalid.
-- `drag_player_index` is set while that player is drag-building.
local function auto_connect(surface, position, family, force, player, drag_player_index)
  local directions = ENDS[family]
  local balancer = STATION_BALANCER[family]
  if not directions then
    return
  end
  local direction = constants.FAMILY_INFO[family].balancer_direction
  -- Tanks: the fluid this tank holds or will hold once the balancers placed
  -- so far are built. A balancer that becomes a ghost joins nothing yet,
  -- so the fluid has to be tracked here, not read off the tank: otherwise
  -- an empty tank between a water row and an oil row would get a ghost
  -- towards each, and robots would join the two.
  local tank = constants.TANK_INFO[family] and find_family(surface, { position = position }, family)[1]
  local joined = tank and fluid_of(tank)

  for _, d in ipairs(directions) do
    local gap_pos = gap_position(position, d)
    local neighbor_pos = {
      x = position.x + d.dx * (HALF_LONG * 2 + GAP),
      y = position.y + d.dy * (HALF_LONG * 2 + GAP),
    }

    -- Matching the family is both "same tier" and "same orientation" at
    -- once -- exactly what link_id sharing requires anyway.
    local neighbors = find_family(surface, { position = neighbor_pos }, family)
    local mixes = false
    if #neighbors > 0 then
      clear_reservations_at(surface, gap_pos)
      local theirs = tank and fluid_of(neighbors[1])
      if joined and theirs and theirs ~= joined then
        mixes = true
        tell(surface, gap_pos, player, { "freight-stations-messages.different-fluids" })
      end
    end
    if
      #neighbors > 0
      and not mixes
      -- also refuses a fluid balancer that would mix two fluids (on 2.0 a
      -- scripted build would delete one of them, FACTORIO_API_NOTES.md §15)
      and surface.can_place_entity({ name = balancer, position = gap_pos, direction = direction, build_check_type = MANUAL })
      -- a blueprint pasting a whole row brings its own balancer ghosts
      and surface.count_entities_filtered({ position = gap_pos, ghost_name = BALANCER_GHOSTS[balancer] }) == 0
    then
      place_balancer(surface, gap_pos, balancer, direction, force, player)
      if tank then
        joined = joined or fluid_of(neighbors[1])
      end
    elseif drag_player_index and #neighbors == 0 and surface.can_place_entity({ name = balancer, position = gap_pos, direction = direction, build_check_type = MANUAL }) then
      reserve_gap(surface, gap_pos, force, drag_player_index)
    end
  end
end

-- Where a station of `family` placed at `position` actually goes (its wagon
-- slot, scripts/rails.lua), or nil and the refusal message.
local function resolve_slot(surface, position, family, force, build_check_type)
  local slot = rails.wagon_slot(surface, position, family)
  if not slot then
    return nil, { "freight-stations-messages.needs-stop", constants.MAX_RAIL_GAP, constants.MAX_TRAIN_CARS }
  end
  if not rails.station_ok(surface, slot, family) then
    return nil, { "freight-stations-messages.needs-rail", constants.MAX_RAIL_GAP }
  end
  local info = constants.FAMILY_INFO[family]
  if not surface.can_place_entity({ name = info.name, position = slot, force = force, build_check_type = build_check_type }) then
    -- for a tank, also a pipe there holding another fluid (a placement
    -- that would mix fluids is refused by the manual build check)
    return nil, { info.tier.fluid and "freight-stations-messages.tank-slot-blocked" or "freight-stations-messages.slot-blocked" }
  end
  return slot
end

-- A station that breaks the placement rules (scripts/rails.lua) is never built:
-- the item goes back to the player who placed it, or onto the ground for a
-- robot or script build, with a message saying why. `item` nil (a ghost)
-- just shows the message.
local function refuse(surface, position, item, quality, player_index, message)
  -- quality.name: every caller passes an entity/ghost quality, but this is
  -- nil-indexed on the cheap path if one ever forgets -- default instead.
  local stack = item and { name = item, count = 1, quality = quality and quality.name or "normal" }
  local player = player_index and game.get_player(player_index)
  if stack and not (player and player.insert(stack) > 0) then
    surface.spill_item_stack({ position = position, stack = stack })
  end
  tell(surface, position, player, message)
end

function placer.swap(placer_entity, player_index)
  if not (placer_entity and placer_entity.valid) then
    return
  end

  local surface = placer_entity.surface
  local position = placer_entity.position
  local direction = placer_entity.direction
  local force = placer_entity.force
  local quality = placer_entity.quality
  local last_user = placer_entity.last_user
  local name = placer_entity.name
  -- from a blueprint: its ghost's wires are on the placer now
  local saved_wires = wires.save(placer_entity)

  local station_tier = PLACER_TIER[name]
  local balancer_tier = BALANCER_PLACER_TIER[name]
  local connect, dragged = false, false
  if station_tier then
    connect, dragged = should_auto_connect(player_index)
  end
  if dragged then
    storage.last_drag_tick[player_index] = game.tick
  end

  placer_entity.destroy()

  -- The real prototypes don't support `direction` at all (linked-container
  -- has no direction_count in 2.0), which is exactly why there are separate
  -- h/v prototypes -- so it's deliberately not passed to create_entity.
  local tier = station_tier or balancer_tier
  local names = DIRECTION_NAMES[tier.key][direction] or DIRECTION_NAMES[tier.key][defines.direction.north]
  -- A new station starts as its own one-station group; the merge that may
  -- follow (scripts/groups.lua) swaps it to the size of the group it joins.
  local real_name = station_tier and constants.FAMILY_INFO[names[1]].name or names[2]
  if station_tier then
    local offset = constants.placer_offset(direction)
    position = { x = position.x + offset.x, y = position.y + offset.y }
    local slot, problem = resolve_slot(surface, position, names[1], force, MANUAL)
    if problem then
      refuse(surface, position, station_tier.item, quality, player_index, problem)
      return
    end
    position = slot
  end

  local entity = surface.create_entity({
    name = real_name,
    position = position,
    force = force,
    quality = quality,
    player = last_user,
  })
  -- Wired before the build event, which may already replace the station
  -- with a resized one (scripts/groups.lua carries the wires over).
  if entity then
    wires.restore(entity, saved_wires)
    script.raise_script_built({ entity = entity })
  end

  -- `entity` is no longer valid if the station joined a group during its own
  -- build event (the resize replaced it), so check the spot instead.
  local placed = (entity and entity.valid)
    or (station_tier and #find_family(surface, { position = position }, names[1]) > 0)
  if placed and connect then
    auto_connect(surface, position, names[1], force, player_index and game.get_player(player_index), dragged and player_index or nil)
  end
end

-- A ghost of anything that sits in the gap between two stations (balancer,
-- steel balancer placer, underground) moves to the nearest gap between
-- wagon slots, the way station ghosts move to their slot. Otherwise a paste
-- whose stations snap leaves its balancers a few tiles off, inside the
-- stations, and those ghosts then block the stations. A flipped paste
-- always does that: the engine can't mirror a station placer's one-sided
-- footprint, so the stations come out a tile off their mirrored balancers
-- (seen with tests/run.ps1 -Player, 2.0.77 and 2.1.21). A ghost with no
-- stop near gets one more look next tick (the paste's own stop may still be
-- coming), then stays where it is.
local function snap_gap_ghost(ghost, player_index, retried)
  local info = GAP_GHOSTS[ghost.ghost_name]
  local surface, position = ghost.surface, ghost.position
  local best, best_shift
  for _, axis in ipairs(info.axes(ghost.direction)) do
    local gap, shift = rails.gap_slot(surface, position, axis, info.tier)
    if gap and (not best_shift or shift < best_shift) then
      best, best_shift = gap, shift
    end
  end
  if not best then
    if not retried then
      table.insert(storage.pending_ghosts, { ghost = ghost, player_index = player_index, gap = true })
      ticker.update()
      return
    end
    -- No gap after the retry: a flipped or shifted paste can put a balancer
    -- ghost past the row's end, or inside what already is / will be a
    -- station's footprint, where it could never be built -- it would sit
    -- there forever blocking robots. Tear it down and hand the item back,
    -- the same way a station ghost with no wagon slot is refused.
    local quality = ghost.quality
    local item = info.item
    ghost.destroy()
    refuse(surface, position, item, quality, player_index, { "freight-stations-messages.no-gap" })
    return
  end
  if best_shift < 0.01 then
    return
  end
  local name, direction, force, quality, last_user = ghost.ghost_name, ghost.direction, ghost.force, ghost.quality, ghost.last_user
  ghost.destroy()
  -- the paste may have brought one for this gap already
  if surface.count_entities_filtered({ position = best, ghost_name = name }) > 0 then
    return
  end
  surface.create_entity({
    name = "entity-ghost",
    inner_name = name,
    position = best,
    direction = direction,
    force = force,
    quality = quality,
    player = last_user,
  })
end

function placer.on_gap_ghost_built(ghost, player_index)
  snap_gap_ghost(ghost, player_index, false)
end

local snap_ghost

-- Moves other ghosts out of the footprint a station ghost is about to take
-- at `slot`. Ghosts of one paste arrive one at a time, so the rest of it
-- hasn't been snapped yet: its balancer ghosts go to their gaps, and
-- station ghosts of the tier to their own slots first (a paste 3 tiles off
-- puts each station ghost's slot inside the next one's footprint). Each of
-- those is destroyed before it looks further, so the chain ends.
local function clear_ghosts(surface, slot, family, player_index)
  local info = constants.FAMILY_INFO[family]
  local half_long, half_wide = constants.STATION_TILES / 2 - 0.01, info.tier.width / 2 - 0.01
  local hx, hy = half_long, half_wide
  if info.axis == "y" then
    hx, hy = half_wide, half_long
  end
  local area = { { slot.x - hx, slot.y - hy }, { slot.x + hx, slot.y + hy } }
  for _, ghost in ipairs(surface.find_entities_filtered({ area = area, ghost_name = info.tier.placer })) do
    if ghost.valid then
      snap_ghost(ghost, player_index, false, true)
    end
  end
  for _, ghost in ipairs(surface.find_entities_filtered({ area = area, ghost_name = GAP_GHOST_NAMES })) do
    if ghost.valid then
      snap_gap_ghost(ghost, player_index, true)
    end
  end
end

-- A station placer's ghost gets the same placement rules as the build
-- itself, applied the moment it's placed: it's moved to its wagon slot, or
-- removed with the reason. Otherwise the ghost would sit where it was
-- clicked and the station would only jump once a robot built it. Dragged
-- ghosts reserve their gaps like dragged builds, so they space per wagon too.
function snap_ghost(ghost, player_index, dragged, retried)
  local surface, force = ghost.surface, ghost.force
  local name, direction = ghost.ghost_name, ghost.direction
  local tier = PLACER_TIER[name]
  local family = (DIRECTION_NAMES[tier.key][direction] or DIRECTION_NAMES[tier.key][defines.direction.north])[1]
  local offset = constants.placer_offset(direction)
  local position = { x = ghost.position.x + offset.x, y = ghost.position.y + offset.y }

  -- see placer.retry_ghosts
  if not retried then
    local slot = rails.wagon_slot(surface, position, family)
    if not (slot and rails.station_ok(surface, slot, family)) then
      table.insert(storage.pending_ghosts, { ghost = ghost, player_index = player_index })
      ticker.update()
      return
    end
  end

  -- out of the way first, or it would block its own slot
  local quality, last_user = ghost.quality, ghost.last_user
  local saved_wires = wires.save(ghost)
  ghost.destroy()
  local target = rails.wagon_slot(surface, position, family)
  if target then
    clear_ghosts(surface, target, family, player_index)
  end
  local slot, problem = resolve_slot(surface, position, family, force, defines.build_check_type.manual_ghost)
  if problem then
    refuse(surface, position, nil, nil, player_index, problem)
    return
  end
  local snapped = surface.create_entity({
    name = "entity-ghost",
    inner_name = name,
    position = { x = slot.x - offset.x, y = slot.y - offset.y },
    direction = direction,
    force = force,
    quality = quality,
    player = last_user,
  })
  if snapped then
    wires.restore(snapped, saved_wires)
  end

  if dragged then
    for _, d in ipairs(ENDS[family]) do
      local gap_pos = gap_position(slot, d)
      local direction = constants.FAMILY_INFO[family].balancer_direction
      if surface.can_place_entity({ name = STATION_BALANCER[family], position = gap_pos, direction = direction, build_check_type = MANUAL }) then
        reserve_gap(surface, gap_pos, force, player_index)
      end
    end
  end
end

function placer.on_ghost_built(ghost, player_index)
  local dragged = false
  if player_index then
    local pending = placer.consume_pre_build(player_index)
    dragged = pending ~= nil and pending.created_by_moving
    if dragged then
      storage.last_drag_tick[player_index] = game.tick
    end
  end
  snap_ghost(ghost, player_index, dragged, false)
end

-- Ghosts of one paste arrive one at a time in no set order, so a station's
-- train stop or rails may still be on their way: one that fails for want of
-- them gets one more look next tick, after the whole paste is down.
function placer.retry_ghosts()
  local pending = storage.pending_ghosts
  if not (pending and pending[1]) then
    return
  end
  storage.pending_ghosts = {}
  for _, p in ipairs(pending) do
    if p.ghost.valid then
      if p.gap then
        snap_gap_ghost(p.ghost, p.player_index, true)
      else
        snap_ghost(p.ghost, p.player_index, false, true)
      end
    end
  end
end

return placer
