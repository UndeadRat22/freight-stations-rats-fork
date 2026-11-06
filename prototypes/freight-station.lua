-- Freight stations, one pair of prototypes (horizontal/vertical) per tier in
-- scripts/constants.lua. Horizontal and vertical are separate prototypes
-- because LinkedContainerPrototype has no `direction_count` and cannot
-- rotate (confirmed against the 2.0.77 docs, see FACTORIO_API_NOTES.md §8).
-- Rotation is handled entirely by the rotatable placer entity
-- (prototypes/placer.lua): the one item places the placer, and its build
-- handler (scripts/placer.lua) swaps in whichever of these two prototypes
-- matches the direction it was placed facing.

local sprite_util = require("prototypes.util")
local constants = require("scripts.constants")
local compat = require("scripts.compat")

local TILES = constants.STATION_TILES

local TIER_ART = sprite_util.TIER_ART

local function station_entity(tier, art, family, axis, size)
  local half_long = TILES / 2
  local half_wide = tier.width / 2
  local collision, selection
  if axis == "x" then
    collision = { { -(half_long - 0.1), -(half_wide - 0.1) }, { half_long - 0.1, half_wide - 0.1 } }
    selection = { { -half_long, -half_wide }, { half_long, half_wide } }
  else
    collision = { { -(half_wide - 0.1), -(half_long - 0.1) }, { half_wide - 0.1, half_long - 0.1 } }
    selection = { { -half_wide, -half_long }, { half_wide, half_long } }
  end

  local entity = {
    type = "linked-container",
    name = constants.station_name(family, size),
    localised_name = { "entity-name." .. family },
    localised_description = { "entity-description." .. family },
    hidden_in_factoriopedia = size > 1,
    icon = art.icon,
    icon_size = 64,
    -- No upgrade path exists, so no size is an upgrade source.
    flags = { "placeable-neutral", "player-creation", "not-upgradable" },
    minable = { mining_time = 0.5, result = tier.item },
    -- Never placed by an item, only through the placer: a hidden one keeps
    -- every size out of the upgrade planner (constants.placeholder).
    placeable_by = { item = constants.placeholder(tier.item), count = 1 },
    max_health = art.health,
    corpse = art.corpse,
    dying_explosion = art.explosion,
    collision_box = collision,
    selection_box = selection,
    gui_mode = "none", -- script owns link_id entirely; no player-facing link GUI
    -- Exactly this group size's capacity: the inventory window shows every
    -- slot, so there's no bar and nothing locked to unlock.
    inventory_size = size * tier.slots,
    inventory_type = "normal",
    picture = sprite_util.station_picture(tier.key, axis),
    -- Like a vanilla chest, a wired station reads out its contents -- which
    -- for a linked container is the whole group's shared inventory, so any
    -- one member reports the group total.
    circuit_connector = sprite_util.station_circuit_connector(tier, axis),
    circuit_wire_max_distance = default_circuit_wire_max_distance,
  }

  -- One deconstruction planner entry per tier: every size and both axes
  -- fold into the size-1 horizontal station, the way vanilla folds curved
  -- rails into straight rail.
  local entry = constants.deconstruction_entry(tier)
  if entity.name ~= entry then
    entity.deconstruction_alternative = entry
  end

  if tier.stack_multiplier then
    -- Steel tier's real advantage over iron beyond footprint: every stack
    -- holds more. Core since base 2.0.56 (FACTORIO_API_NOTES.md §1).
    entity.inventory_type = "with_custom_stack_size"
    entity.inventory_properties = {
      stack_size_multiplier = tier.stack_multiplier,
      with_bar = false,
    }
  end
  return entity
end

-- The stand-in a station marked for deconstruction turns into (see
-- scripts/dismantle.lua): looks like a lone station, holds one station's
-- slots, and gives the station item when robots finally mine it.
local function dismantling_entity(tier, art, family, axis)
  local entity = station_entity(tier, art, family, axis, 1)
  entity.type = "container"
  entity.circuit_connector = compat.container_circuit_connector(entity.circuit_connector)
  entity.name = constants.dismantling_name(family)
  entity.deconstruction_alternative = constants.deconstruction_entry(tier)
  entity.localised_name = { "entity-name.freight-station-dismantling", { "entity-name." .. family } }
  entity.localised_description = { "entity-description.freight-station-dismantling" }
  entity.hidden = true
  entity.hidden_in_factoriopedia = true
  entity.flags = { "placeable-neutral", "player-creation", "not-blueprintable", "not-upgradable", "no-copy-paste" }
  entity.placeable_by = nil
  entity.gui_mode = nil
  return entity
end

for _, tier in ipairs(constants.TIERS) do
  local art = TIER_ART[tier.key]
  for size = 1, tier.max_group do
    data:extend({
      station_entity(tier, art, tier.station_h, "x", size),
      station_entity(tier, art, tier.station_v, "y", size),
    })
  end
  data:extend({
    dismantling_entity(tier, art, tier.station_h, "x"),
    dismantling_entity(tier, art, tier.station_v, "y"),
  })
  data:extend({
    {
      type = "item",
      name = tier.item,
      icon = art.icon,
      icon_size = 64,
      subgroup = sprite_util.SUBGROUP,
      order = sprite_util.order(tier, "a[station]"),
      place_result = tier.placer,
      stack_size = 10,
    },
  })
end
