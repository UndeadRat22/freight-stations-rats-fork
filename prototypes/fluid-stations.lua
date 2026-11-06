-- Fluid stations, fluid balancers and underground fluid balancers, per tank tier
-- in scripts/constants.lua (constants.TANK_TIERS).
--
-- A tank is a storage-tank. Tanks joined by balancers form one fluid
-- segment, which the engine shares and splits the way a group shares one
-- linked inventory, so no script keeps groups for them (FACTORIO_API_NOTES.md
-- Â§15). Like stations they are separate horizontal/vertical prototypes that
-- don't turn, placed through the rotatable placer (prototypes/placer.lua),
-- so the wagon slots, the rail rule and the blueprint swap work the same.
--
-- Pipe connections: a tank connects on every tile of both long sides (a
-- pump between it and the track can sit anywhere along a wagon, and the
-- wagon's pump spots differ between 2.0 and 2.1) and on every tile of both
-- ends (its balancers). Balancers connect only along the row: nothing
-- pumps into the gap (on 2.1 one of a wagon's pump spots is level with it,
-- but the tank tiles cover the others on both versions).

local sprite_util = require("prototypes.util")
local constants = require("scripts.constants")
local compat = require("scripts.compat")

local TILES = constants.STATION_TILES
local N, E, S, W = defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west

-- Category of the underground connections, one per tier: they pair only
-- with their own tier's, never with a vanilla pipe-to-ground.
local UNDERGROUND_CATEGORY = "fluid-station-underground-"
-- max_underground_distance 10 paired across up to 9 empty tiles (probe,
-- 2.0.77 and 2.1.21), so this gives the stations' UNDERGROUND_MAX_GAP.
local UNDERGROUND_DISTANCE = constants.UNDERGROUND_MAX_GAP + 1

local TIER_ART = sprite_util.TIER_ART
local VANILLA = data.raw["storage-tank"]["storage-tank"]

-- Every connection on the outline of a box `lx` x `ly` tiles (north
-- orientation): one per edge tile, pointing out of it.
local function outline_connections(lx, ly)
  local list = {}
  for i = 0, lx - 1 do
    local x = -lx / 2 + 0.5 + i
    list[#list + 1] = { direction = N, position = { x, -ly / 2 + 0.5 } }
    list[#list + 1] = { direction = S, position = { x, ly / 2 - 0.5 } }
  end
  for j = 0, ly - 1 do
    local y = -ly / 2 + 0.5 + j
    list[#list + 1] = { direction = W, position = { -lx / 2 + 0.5, y } }
    list[#list + 1] = { direction = E, position = { lx / 2 - 0.5, y } }
  end
  return list
end

local EMPTY = { filename = "__core__/graphics/empty.png", size = 1 }

-- How a tank shows its connections, after the vanilla machines: along the
-- long sides (every tile connects) a vanilla pipe stub is drawn only where
-- a pump or pipe is attached (`pipe_picture` with draw_only_when_connected).
-- No caps anywhere (`pipe_covers`): one on every free side tile lined the
-- whole side with them, and the ends have their own flanged nozzles in the
-- sprite. `ends` are the directions of the ends ("east"/"west" for a
-- horizontal tank), which draw nothing either: a balancer continues them.
--
-- Nothing is drawn for connections facing north, the far side: the tank's
-- body rises in front of that tile, so a stub there would be painted over
-- the body (connector pictures draw in front of the entity). The pipe or
-- pump attached there already disappears behind the tank by itself. (A
-- storage tank has one fluid box, so its draw order can't be set per side:
-- drawing it behind the body, as vanilla assemblers do, also hid the stubs
-- on the near side.)
local function tank_connector_pictures(tier, ends)
  -- taken from the vanilla prototypes, not the base game's helper functions
  -- (2.1 no longer has assembler2pipepictures as a global)
  local machine = data.raw["assembling-machine"][tier.width > 1 and "assembling-machine-3" or "assembling-machine-2"]
  local stubs = machine.fluid_boxes[1].pipe_picture
  local picture = {}
  for _, d in ipairs({ "north", "east", "south", "west" }) do
    if d == "north" or ends[d] then
      picture[d] = EMPTY
    else
      picture[d] = stubs[d]
    end
  end
  return picture
end

local function boxes(lx, ly)
  return { { -(lx / 2 - 0.1), -(ly / 2 - 0.1) }, { lx / 2 - 0.1, ly / 2 - 0.1 } }, { { -lx / 2, -ly / 2 }, { lx / 2, ly / 2 } }
end

-- What every tank-tier storage tank shares.
local function storage_tank(spec)
  local entity = {
    type = "storage-tank",
    icon_size = 64,
    -- No upgrade path exists, so keep it out of the upgrade planner.
    flags = { "placeable-neutral", "player-creation", "not-upgradable" },
    two_direction_only = false,
    -- no level window (balancers); tanks set their sight glass
    window_bounding_box = { { 0, 0 }, { 0, 0 } },
    flow_length_in_ticks = 360,
    impact_category = "metal-large",
    -- sounds of the vanilla storage tank, whatever a mod made them
    open_sound = VANILLA.open_sound,
    close_sound = VANILLA.close_sound,
    working_sound = VANILLA.working_sound,
  }
  for k, v in pairs(spec) do
    entity[k] = v
  end
  compat.hide_connection_info(entity.fluid_box)
  return entity
end

local function tank_entity(tier, family, axis)
  local art = TIER_ART[tier.key]
  local lx, ly = TILES, tier.width
  if axis == "y" then
    lx, ly = ly, lx
  end
  local collision, selection = boxes(lx, ly)
  local connector = sprite_util.station_circuit_connector(tier, axis)
  local stubs = tank_connector_pictures(tier, axis == "x" and { east = true, west = true } or { north = true, south = true })
  return storage_tank({
    name = family,
    localised_name = { "entity-name." .. tier.station_h },
    localised_description = { "entity-description." .. tier.station_h },
    icon = art.icon,
    flags = { "placeable-neutral", "player-creation", "not-upgradable", "not-rotatable" },
    minable = { mining_time = 0.5, result = tier.item },
    -- only built through the placer (constants.placeholder)
    placeable_by = { item = constants.placeholder(tier.item), count = 1 },
    -- both axes are one entry in the deconstruction planner
    deconstruction_alternative = family ~= tier.station_h and tier.station_h or nil,
    max_health = art.health,
    corpse = art.corpse,
    dying_explosion = art.explosion,
    collision_box = collision,
    selection_box = selection,
    fluid_box = {
      volume = tier.volume,
      pipe_connections = outline_connections(lx, ly),
      pipe_picture = stubs,
      -- stubs only where something is attached
      draw_only_when_connected = true,
    },
    -- The fluid level shows in a sight glass, like the vanilla tank's
    -- window: the engine draws the window background and the level behind
    -- the picture, which is see-through there (tools/sprites/render_tanks.py).
    window_bounding_box = sprite_util.tank_window(tier.key, axis),
    pictures = {
      picture = sprite_util.station_picture(tier.key, axis),
      window_background = sprite_util.tank_window_background(tier.key, axis),
      fluid_background = VANILLA.pictures.fluid_background,
      flow_sprite = VANILLA.pictures.flow_sprite,
      gas_flow = VANILLA.pictures.gas_flow,
    },
    -- reads the tank's fluid like a vanilla storage tank; any one tank of
    -- a row reads the shared segment's level
    circuit_connector = { connector, connector, connector, connector },
    circuit_wire_max_distance = default_circuit_wire_max_distance,
  })
end

-- North-facing: in a row along x, `width` tiles across it. Connects only
-- at its two row ends, one connection per tile across.
local function balancer_entity(tier)
  local w = tier.width
  local collision, selection = boxes(1, w)
  local x, y = sprite_util.tank_balancer_picture(tier.key, "x"), sprite_util.tank_balancer_picture(tier.key, "y")
  local connections = {}
  for j = 0, w - 1 do
    local cy = -w / 2 + 0.5 + j
    connections[#connections + 1] = { direction = W, position = { 0, cy } }
    connections[#connections + 1] = { direction = E, position = { 0, cy } }
  end
  return storage_tank({
    name = tier.balancer_h,
    icon = sprite_util.icon("fluid-balancer", tier.key),
    minable = { mining_time = 0.2, result = tier.balancer_item },
    max_health = 150,
    corpse = "small-remnants",
    collision_box = collision,
    -- collision_mask (walkable, like a belt): set in data-final-fixes.lua
    selection_box = selection,
    -- turns between a row along x (north) and along y (east), and must stay
    -- rotatable anyway: a blueprint holding a not-rotatable entity can't be
    -- rotated (seen with tests/run.ps1 -Player)
    two_direction_only = true,
    fast_replaceable_group = "freight-stations-fluid-balancer-" .. tier.key,
    -- like a pipe: only the tanks show their fluid in alt mode
    show_fluid_icon = false,
    fluid_box = {
      volume = 500,
      pipe_connections = connections,
    },
    pictures = { picture = { north = x, east = y, south = x, west = y } },
  })
end

-- North-facing: across the track (north), in a row along x. Connects along
-- its row like a balancer, and from its front tile underground to the one
-- facing it across the track.
local function underground_entity(tier)
  local w = tier.width
  local collision, selection = boxes(1, w)
  local connections = {}
  for j = 0, w - 1 do
    local y = -w / 2 + 0.5 + j
    connections[#connections + 1] = { direction = W, position = { 0, y } }
    connections[#connections + 1] = { direction = E, position = { 0, y } }
  end
  connections[#connections + 1] = {
    direction = N,
    position = { 0, -w / 2 + 0.5 },
    connection_type = "underground",
    max_underground_distance = UNDERGROUND_DISTANCE,
    connection_category = UNDERGROUND_CATEGORY .. tier.key,
  }
  local pictures = {}
  for _, name in ipairs({ "north", "east", "south", "west" }) do
    pictures[name] = sprite_util.tank_underground_picture(tier.key, name)
  end
  return storage_tank({
    name = tier.underground,
    localised_description = { "entity-description." .. tier.underground, tostring(constants.UNDERGROUND_MAX_GAP) },
    icon = sprite_util.icon("underground-fluid-balancer", tier.key),
    minable = { mining_time = 0.2, result = tier.underground_item },
    max_health = 200,
    corpse = "small-remnants",
    collision_box = collision,
    -- collision_mask (walkable, like a belt): set in data-final-fixes.lua
    selection_box = selection,
    fast_replaceable_group = "freight-stations-fluid-balancer-" .. tier.key,
    show_fluid_icon = false,
    fluid_box = {
      volume = 500,
      pipe_connections = connections,
    },
    pictures = { picture = pictures },
  })
end

local function item(name, icon, order, place_result, stack_size)
  return {
    type = "item",
    name = name,
    icon = icon,
    icon_size = 64,
    subgroup = sprite_util.SUBGROUP,
    order = order,
    place_result = place_result,
    stack_size = stack_size,
  }
end

for _, tier in ipairs(constants.TANK_TIERS) do
  data:extend({
    tank_entity(tier, tier.station_h, "x"),
    tank_entity(tier, tier.station_v, "y"),
    balancer_entity(tier),
    underground_entity(tier),
    item(tier.item, TIER_ART[tier.key].icon, sprite_util.order(tier, "a[station]"), tier.placer, 10),
    item(tier.balancer_item, sprite_util.icon("fluid-balancer", tier.key), sprite_util.order(tier, "b[balancer]"), tier.balancer_h, 50),
    item(tier.underground_item, sprite_util.icon("underground-fluid-balancer", tier.key), sprite_util.order(tier, "c[underground]"), tier.underground, 50),
  })
end
