-- Swaps a just-built placer for the real (non-rotatable) station or balancer
-- it represents, then -- only for drag-built or blueprint/robot builds, never
-- a single deliberate placement -- fills either open gap next to a station
-- with a balancer if a matching station already sits exactly one tile away.
-- Stations build exactly where their placer was: there is no rail-adjacency
-- rule and no wagon-slot snapping.
local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
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

-- Everything that sits in the gap between two stations (balancers, balancer
-- placers, undergrounds), for the stranded-ghost cleanup in placer.swap.
local GAP_GHOST_SET = {}
for _, tier in ipairs(constants.ALL_TIERS) do
  for _, name in ipairs({ tier.balancer_placer, tier.balancer_h, tier.balancer_v, tier.underground }) do
    if name then
      GAP_GHOST_SET[name] = true
    end
  end
end
local GAP_GHOST_NAMES = {}
for name in pairs(GAP_GHOST_SET) do
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

-- Undo provenance limits (see placer.on_undo_applied).
local UNDO_MARGIN = 8
local UNDO_RECORD_LIMIT = 1024

-- Stable key for a position on the half-tile grid (station/placer centres).
local function half_tile_key(position)
  return math.floor(position.x * 2) .. "," .. math.floor(position.y * 2)
end

function placer.is_placer(name)
  return constants.PLACERS[name] == true
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
    -- The station sits half a tile toward the placer's local west of the
    -- placer's position (prototypes/placer.lua); otherwise it builds exactly
    -- where the placer stood. The engine checked the placer's collision box
    -- (station + the drag-spacing layer) before building it, so the smaller
    -- station box always fits.
    local offset = constants.placer_offset(direction)
    position = { x = position.x + offset.x, y = position.y + offset.y }
  end

  local entity = surface.create_entity({
    name = real_name,
    position = position,
    force = force,
    quality = quality,
    player = last_user,
  })
  if not entity then
    -- creation raced against something else taking the spot in the same
    -- tick: hand the item back rather than letting it vanish with the placer
    local item = station_tier and station_tier.item or balancer_tier.balancer_item
    local stack = { name = item, count = 1, quality = quality and quality.name or "normal" }
    local player = player_index and game.get_player(player_index)
    if not (player and player.insert(stack) > 0) then
      surface.spill_item_stack({ position = position, stack = stack })
    end
    return
  end

  -- Undo provenance: the swap replaces the built placer (part of the
  -- engine's undo record for a blueprint paste) with a script-created
  -- station, severing that record - cmd+z would undo everything around
  -- the station but never the station itself. Record who got the station
  -- and where, so placer.on_undo_applied can remove it when an undo
  -- removes entities around it.
  local owner = player_index or (last_user and last_user.index)
  if owner then
    local by_surface = storage.swapped_stations
    local records = by_surface[surface.index]
    if not records then
      records = {}
      by_surface[surface.index] = records
    end
    -- safety valve: this is a convenience history, not a data structure
    -- of record; when it somehow grows unbounded, start over rather than
    -- growing without limit.
    local count = 0
    for _ in pairs(records) do
      count = count + 1
    end
    if count > UNDO_RECORD_LIMIT then
      records = {}
      by_surface[surface.index] = records
    end
    records[half_tile_key(entity.position)] = { player = owner, tick = game.tick }
  end
  wires.restore(entity, saved_wires)
  script.raise_script_built({ entity = entity })

  if station_tier then
    -- A flipped or shifted paste lands its balancer ghosts a tile off the
    -- stations (the engine can't mirror the placer's one-sided footprint),
    -- inside the station that just got built, where they could never be
    -- built by anything. Remove them instead of leaving them stuck forever;
    -- a ghost costs no item, so there is nothing to hand back. Auto-connect
    -- puts balancers into the real gaps.
    local info = constants.FAMILY_INFO[names[1]]
    local half_wide = info.tier.width / 2
    local hx, hy = HALF_LONG, half_wide
    if info.axis == "y" then
      hx, hy = half_wide, HALF_LONG
    end
    for _, ghost in ipairs(surface.find_entities_filtered({
      area = { { position.x - hx, position.y - hy }, { position.x + hx, position.y + hy } },
      ghost_name = GAP_GHOST_NAMES,
    })) do
      if ghost.valid then
        ghost.destroy()
      end
    end
  end

  -- `entity` is no longer valid if the station joined a group during its own
  -- build event (the resize replaced it), so check the spot instead.
  local placed = (entity and entity.valid)
    or (station_tier and #find_family(surface, { position = position }, names[1]) > 0)
  if placed and connect then
    auto_connect(surface, position, names[1], force, player_index and game.get_player(player_index), dragged and player_index or nil)
  end
end

-- Undo support, paired with the swap-side record: an undo that removed
-- entities around a recorded swap of the same player removes the swapped-in
-- station too, refunding the station item. The engine's own undo record
-- points at the placer the swap destroyed, so without this the stations
-- would be the one thing cmd+z leaves behind.
function placer.on_undo_applied(event)
  local actions = event.actions
  if not (actions and actions[1]) then
    return
  end
  local box, surface_index
  for _, action in ipairs(actions) do
    if action.type == "removed-entity" and action.target then
      surface_index = surface_index or action.surface_index
      local p = action.target.position
      if p then
        if not box then
          box = { x0 = p.x, y0 = p.y, x1 = p.x, y1 = p.y }
        else
          box.x0, box.x1 = math.min(box.x0, p.x), math.max(box.x1, p.x)
          box.y0, box.y1 = math.min(box.y0, p.y), math.max(box.y1, p.y)
        end
      end
    end
  end
  if not (box and surface_index) then
    return
  end
  box.x0, box.y0 = box.x0 - UNDO_MARGIN, box.y0 - UNDO_MARGIN
  box.x1, box.y1 = box.x1 + UNDO_MARGIN, box.y1 + UNDO_MARGIN
  local surface = game.get_surface(surface_index)
  local by_surface = storage.swapped_stations[surface_index]
  if not (surface and by_surface) then
    return
  end
  local player = event.player_index and game.get_player(event.player_index)
  for key, record in pairs(by_surface) do
    if not event.player_index or record.player == event.player_index then
      local x, y = key:match("^(-?%d+),(-?%d+)$")
      x, y = tonumber(x), tonumber(y)
      if x and x >= box.x0 and x <= box.x1 and y and y >= box.y0 and y <= box.y1 then
        by_surface[key] = nil
        local station = geometry.find_stations(surface, { position = { x = x / 2, y = y / 2 } })[1]
        if station then
          local tier = constants.STATION_INFO[station.name].tier
          local item = { name = tier.item, count = 1, quality = station.quality.name }
          if not (player and player.insert(item) > 0) then
            surface.spill_item_stack({ position = station.position, stack = item })
          end
          -- raises script_raised_destroy, so the group redistributes the
          -- station's contents the normal way
          station.destroy({ raise_destroy = true })
        end
      end
    end
  end
end

return placer
