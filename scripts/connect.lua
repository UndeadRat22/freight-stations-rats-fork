-- Auto-connect: whenever a station is built with a matching neighbour
-- exactly one gap away (the 7-tile pitch that lines a station up with each
-- wagon), a balancer is placed between them automatically, paid for from
-- the builder's inventory. Without a builder or the item, nothing happens.
local constants = require("scripts.constants")
local geometry = require("scripts.geometry")

local connect = {}

-- For every placement check: the default build check (ghost_revive) refuses
-- spots with loose items on the ground, which a player can build over
-- (confirmed headless, 2.0.77).
local MANUAL = defines.build_check_type.manual

local ENDS = { -- family -> the two ends to probe for a neighbour
  x = { { dx = 1, dy = 0 }, { dx = -1, dy = 0 } },
  y = { { dx = 0, dy = 1 }, { dx = 0, dy = -1 } },
}
local BALANCER = {} -- family -> the tier's balancer prototype
local BALANCER_ITEM = {} -- balancer prototype -> its item
local BALANCER_DIRECTION = { x = defines.direction.north, y = defines.direction.east }
for _, tier in ipairs(constants.ALL_TIERS) do
  BALANCER[tier.station_h] = tier.balancer
  BALANCER[tier.station_v] = tier.balancer
  BALANCER_ITEM[tier.balancer] = tier.balancer_item
end

local HALF_LONG = constants.STATION_TILES / 2
local GAP = constants.GAP

local function family_of(name)
  local info = constants.FAMILY_INFO[name]
  return info and info.family
end

-- The fluid a tank holds (its row's), or nil when it's empty.
local function fluid_of(tank)
  return (next(tank.get_fluid_contents()))
end

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

local function place_balancer(surface, position, balancer, direction, force, player)
  -- An auto-placed balancer costs one balancer item, like any other build,
  -- paid from the builder's inventory (free in cheat mode). Without a
  -- builder, or without the item, nothing is placed: no ghost by proxy,
  -- the connection is simply not made until one is built or pasted there.
  local charged = false
  if not player then
    return
  end
  if not player.cheat_mode then
    charged = player.remove_item({ name = BALANCER_ITEM[balancer], count = 1 }) > 0
    if not charged then
      return
    end
  end
  local created = surface.create_entity({
    name = balancer,
    position = position,
    direction = direction,
    force = force,
    player = player,
    raise_built = true,
  })
  if not created and charged then
    -- the spot was taken in the same tick, between the placement check and
    -- the build: hand the item back rather than eat it
    player.insert({ name = BALANCER_ITEM[balancer], count = 1 })
  end
end

function connect.on_station_built(entity, player_index)
  local family = family_of(entity.name)
  local info = constants.FAMILY_INFO[family]
  if not info then
    return
  end
  local surface = entity.surface
  local position = entity.position
  local force = entity.force
  local player = player_index and game.get_player(player_index)
  local balancer = BALANCER[family]
  local direction = BALANCER_DIRECTION[info.axis]

  -- Tanks: the fluid this tank holds or will hold once the balancers placed
  -- so far are built. A balancer that becomes a ghost joins nothing yet, so
  -- the fluid has to be tracked here, not read off the tank: otherwise an
  -- empty tank between a water row and an oil row would get a ghost towards
  -- each, and robots would join the two.
  local tank = constants.TANK_INFO[family]
  local joined = tank and fluid_of(entity)

  for _, d in ipairs(ENDS[info.axis]) do
    local gap_pos = {
      x = position.x + d.dx * (HALF_LONG + GAP / 2),
      y = position.y + d.dy * (HALF_LONG + GAP / 2),
    }
    local neighbor_pos = {
      x = position.x + d.dx * (HALF_LONG * 2 + GAP),
      y = position.y + d.dy * (HALF_LONG * 2 + GAP),
    }
    -- Matching the family is both "same tier" and "same orientation" at
    -- once -- exactly what sharing one inventory requires anyway.
    local neighbors = tank
      and surface.find_entities_filtered({ position = neighbor_pos, name = family })
      or geometry.find_stations(surface, { position = neighbor_pos }, family)
    if #neighbors > 0 then
      local mixes = false
      if tank then
        local theirs = fluid_of(neighbors[1])
        if joined and theirs and theirs ~= joined then
          mixes = true
          tell(surface, gap_pos, player, { "freight-stations-messages.different-fluids" })
        end
      end
      if
        not mixes
        -- also refuses a fluid balancer that would mix two fluids (on 2.0 a
        -- scripted build would delete one of them, FACTORIO_API_NOTES.md §15)
        and surface.can_place_entity({ name = balancer, position = gap_pos, direction = direction, build_check_type = MANUAL })
        -- a blueprint pasting a whole row brings its own balancer ghosts
        and surface.count_entities_filtered({ position = gap_pos, ghost_name = balancer }) == 0
      then
        place_balancer(surface, gap_pos, balancer, direction, force, player)
        if tank then
          joined = joined or fluid_of(neighbors[1])
        end
      end
    end
  end
end

return connect
