-- The rotatable placers. LinkedContainerPrototype can't rotate at all
-- (confirmed, see freight-station.lua and FACTORIO_API_NOTES.md §8), so the
-- items place these instead: a plain assembling-machine with no usable
-- recipe, purely so it can exist in 4 directions with a non-square box.
-- Confirmed empirically (headless engine test, 2026-10-09) against 2.0.77:
--   - direction DOES correctly rotate a non-square, even ASYMMETRIC
--     collision_box (tested north/south/east/west, including through full
--     ghost-revival, i.e. the actual blueprint/robot-build code path).
--   - `mirror` does NOT affect collision_box at all for this entity type, so
--     a blueprint FLIP of the station placer is an UNRESOLVED RISK needing an
--     in-game check. Fallback per the spec: place the real station directly
--     and shift it when drag-built, instead of using a placer at all.
--
-- The station placer's tile_width is 7 (station + gap) so an odd width
-- centres it on a tile centre; its collision box is just the 6-tile station,
-- half a tile toward local west of the placer's position
-- (constants.placer_offset), which scripts/placer.lua and
-- scripts/blueprint.lua apply in each direction. Drag spacing does NOT come
-- from the placer: the engine spaces dragged entities by what's in the
-- world, and the placer is swapped for the station at once, so
-- scripts/placer.lua reserves gap tiles while dragging (see the reservation
-- entity at the bottom of this file).
local constants = require("scripts.constants")
local sprite_util = require("prototypes.util")

local GAP = constants.GAP
local LENGTH = constants.STATION_TILES + GAP -- 7

-- `pictures` is an Animation4Way. Without graphics the placer is
-- invisible, and so are the cursor preview while placing and the ghosts of
-- every blueprint (blueprints store placers, see scripts/blueprint.lua).
local function void_machine(name, icon, result, tile_width, tile_height, collision, selection, pictures, group)
  return {
    type = "assembling-machine",
    name = name,
    icon = icon,
    icon_size = 64,
    -- No upgrade path exists, so keep it out of the upgrade planner.
    flags = { "placeable-neutral", "player-creation", "not-upgradable" },
    -- Same group as what the machine turns into (or replaces): a blueprint
    -- ghost of a placer can then be built over an existing station, exactly
    -- like vanilla containers build over each other.
    fast_replaceable_group = group,
    minable = { mining_time = 0.5, result = result },
    max_health = 400,
    tile_width = tile_width,
    tile_height = tile_height,
    collision_box = collision,
    selection_box = selection,
    -- No recipe ever belongs to this category, so there's nothing to craft
    -- and nothing for a player to configure even if the entity briefly
    -- shows its GUI before the build handler destroys it.
    crafting_categories = { "freight-station-placer-none" },
    crafting_speed = 1,
    energy_source = { type = "void" },
    energy_usage = "1W",
    graphics_set = { animation = pictures },
  }
end

data:extend({ { type = "recipe-category", name = "freight-station-placer-none" } })

for _, tier in ipairs(constants.ALL_TIERS) do
  local w = tier.width / 2
  local function station_picture(axis, direction)
    local offset = constants.placer_offset(direction)
    return sprite_util.station_picture(tier.key, axis, offset)
  end
  -- Same connector as the station it becomes, so a blueprint keeps a
  -- station's circuit wires (it stores the placer, see
  -- scripts/blueprint.lua) and scripts/placer.lua can hand them over.
  local function station_connector(axis, direction)
    return sprite_util.station_circuit_connector(tier, axis, constants.placer_offset(direction))
  end
  -- collision_mask: set in data-final-fixes.lua
  local station_placer = void_machine(
      tier.placer,
      sprite_util.TIER_ART[tier.key].icon,
      tier.item,
      LENGTH,
      tier.width,
      -- the station part only (local west of the gap); spacing comes from the
      -- drag reservations, and a box over the gap tile would collide with them
      { { -(LENGTH / 2 - 0.1), -(w - 0.1) }, { LENGTH / 2 - GAP - 0.1, w - 0.1 } },
      { { -LENGTH / 2, -w }, { LENGTH / 2 - GAP, w } },
      {
        north = station_picture("x", defines.direction.north),
        east = station_picture("y", defines.direction.east),
        south = station_picture("x", defines.direction.south),
        west = station_picture("y", defines.direction.west),
      },
      -- the station group: a placer ghost can be built over a station
      "freight-stations-station"
    )
  station_placer.circuit_connector = {
    station_connector("x", defines.direction.north),
    station_connector("y", defines.direction.east),
    station_connector("x", defines.direction.south),
    station_connector("y", defines.direction.west),
  }
  station_placer.circuit_wire_max_distance = default_circuit_wire_max_distance
  -- listed under the station in the deconstruction planner (stations, ghosts)
  station_placer.deconstruction_alternative = tier.fluid and tier.station_h or constants.deconstruction_entry(tier)
  data:extend({ station_placer })

  if tier.balancer_placer then
    -- Balancer for a 2-wide tier fills the 1-tile gap across the full
    -- width: 1 x width. North/south -> "-h" prototype (gap between
    -- horizontal stations), east/west -> "-v" (see scripts/placer.lua).
    local balancer_placer = void_machine(
      tier.balancer_placer,
      sprite_util.icon("stock-balancer", tier.key),
      tier.balancer_item,
      1,
      tier.width,
      { { -0.4, -(w - 0.1) }, { 0.4, w - 0.1 } },
      { { -0.5, -w }, { 0.5, w } },
      {
        north = sprite_util.balancer_picture(tier.key, "x"),
        east = sprite_util.balancer_picture(tier.key, "y"),
        south = sprite_util.balancer_picture(tier.key, "x"),
        west = sprite_util.balancer_picture(tier.key, "y"),
      },
      -- the balancer's own group (shared with its underground, see
      -- stock-balancer.lua): a balancer placer ghost can be built over a
      -- real balancer
      "freight-stations-balancer-" .. tier.key
    )
    balancer_placer.deconstruction_alternative = tier.balancer_h
    -- collision_mask: the balancer's own, set in data-final-fixes.lua
    data:extend({ balancer_placer })
  end
end

-- Drag-spacing reservation (scripts/placer.lua): sits invisibly in a gap tile
-- while a row is being dragged. Its collision layer is one only the station
-- placers check, so it blocks the next dragged station from landing in the
-- gap without getting in the way of players, belts, inserters or balancers.
data:extend({
  { type = "collision-layer", name = "freight-station-gap" },
  {
    type = "simple-entity-with-owner",
    name = "freight-station-gap-reservation",
    icon = "__base__/graphics/icons/iron-gear-wheel.png",
    icon_size = 64,
    flags = { "not-on-map", "not-blueprintable", "not-deconstructable", "no-copy-paste", "not-repairable" },
    hidden = true,
    selectable_in_game = false,
    collision_box = { { -0.4, -0.4 }, { 0.4, 0.4 } },
    collision_mask = { layers = { ["freight-station-gap"] = true } },
    picture = { filename = "__core__/graphics/empty.png", size = 1 },
  },
})
